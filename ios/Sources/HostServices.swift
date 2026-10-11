import Foundation
import Combine
import Darwin
import Metal
import Network
import Security
import UniformTypeIdentifiers

@MainActor
final class ExternalVMBundle: ObservableObject {
    @Published private(set) var diskPath: String?
    @Published private(set) var bundleSummary = "No VM selected"
    @Published private(set) var firmwareVersion = "Unknown"
    private var bookmarked: Data?
    private var activeURL: URL?
    private var acquiredAccess = false

    var isDiskAccessible: Bool {
        guard let activeURL, let diskPath else { return false }
        return FileManager.default.isReadableFile(atPath: activeURL.appendingPathComponent("config.plist").path)
            && FileManager.default.isReadableFile(atPath: diskPath)
    }

    init() {
        bookmarked = UserDefaults.standard.data(forKey: "vphone.usb.folder.bookmark")
        if let bookmarked {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmarked, options: [], relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
                diskPath = url.path
            }
        }
    }

    func select(_ url: URL) throws {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let bundle = try VPhoneBundle.load(at: url)
        let image = bundle.manifest.diskImage
        let restored = VPhoneRestoreInfo.load(fromBundle: bundle)
        guard !image.contains(".."), !image.hasPrefix("/") else {
            throw VPhoneStorageError.invalidImagePath
        }
        let disk = url.appendingPathComponent(image)
        guard FileManager.default.fileExists(atPath: disk.path) else {
            throw VPhoneStorageError.missingDisk(disk.lastPathComponent)
        }
        let bookmark = try url.bookmarkData()
        bookmarked = bookmark
        UserDefaults.standard.set(bookmark, forKey: "vphone.usb.folder.bookmark")
        diskPath = disk.path
        firmwareVersion = restored.map { "iOS \($0.ios.version) (\($0.ios.build)) + cloudOS \($0.cloudOS.version)" } ?? "Firmware restore information not recorded"
        bundleSummary = "\(bundle.name) · \(bundle.manifest.cpuCount) CPU · \(bundle.manifest.memorySize / (1024 * 1024)) MB · \(firmwareVersion)"
    }

    func beginAccess() -> URL? {
        if let activeURL { return activeURL }
        guard let bookmarked else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarked, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale, url.startAccessingSecurityScopedResource() else { return nil }
        guard FileManager.default.isReadableFile(atPath: url.appendingPathComponent("config.plist").path) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        activeURL = url
        acquiredAccess = true
        return url
    }

    func endAccess() {
        if acquiredAccess { activeURL?.stopAccessingSecurityScopedResource() }
        activeURL = nil
        acquiredAccess = false
    }
}

enum VPhoneStorageError: LocalizedError {
    case invalidImagePath
    case missingDisk(String)
    var errorDescription: String? {
        switch self {
        case .invalidImagePath: "Disk image path must stay inside the selected VM folder."
        case let .missingDisk(name): "Missing disk image \(name) in the VM folder."
        }
    }
}

@MainActor
final class PairingRecordStore: ObservableObject {
    @Published var status = "No pairing file imported"
    private let service = "com.nightvibes33.vphoneios.pairing"
    var available: Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func importFile(_ url: URL) throws {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count < 1_000_000,
              (try PropertyListSerialization.propertyList(from: data, format: nil)) is [String: Any] else {
            throw PairingError.invalid
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let result = SecItemAdd(attrs as CFDictionary, nil)
        guard result == errSecSuccess else { throw PairingError.keychain(result) }
        status = "Encrypted pairing record stored in this device's Keychain. Not used as a VM entitlement."
    }

    func recordData() -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

enum PairingError: LocalizedError {
    case invalid, keychain(OSStatus)
    var errorDescription: String? {
        switch self {
        case .invalid: "File is not a valid pairing property list."
        case let .keychain(code): "Keychain error \(code)."
        }
    }
}

@MainActor
final class LocalTunnel: ObservableObject {
    @Published var host = "10.7.0.3"
    @Published var port = "49152"
    @Published var status = "Not checked · LocalDevVPN must be started separately"
    private var connection: NWConnection?
    private var probeToken = UUID()

    func check() {
        connection?.cancel()
        guard let number = UInt16(port), number > 0, !host.isEmpty,
              let nwPort = NWEndpoint.Port(rawValue: number) else {
            status = "Invalid tunnel host or port."
            return
        }
        let token = UUID()
        probeToken = token
        status = "Connecting to \(host):\(number)…"
        let client = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        connection = client
        client.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.probeToken == token else { return }
                switch state {
                case .ready:
                    self.status = "TCP endpoint reachable · RSD/pairing protocol not authenticated"
                    client.cancel()
                case .failed(let error):
                    self.status = "Tunnel endpoint failed: \(error.localizedDescription)"
                    client.cancel()
                default: break
                }
            }
        }
        client.start(queue: .global(qos: .userInitiated))
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard probeToken == token, status.hasPrefix("Connecting") else { return }
            status = "Tunnel endpoint timed out"
            client.cancel()
        }
    }
}

struct HostCapabilities {
    let metal: String
    let jit: String
    let virtualization: String

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            metal = "Metal device: \(device.name)"
        } else {
            metal = "Metal unavailable"
        }
        let ptr = mmap(nil, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | 0x800, -1, 0)
        if ptr == MAP_FAILED {
            jit = "MAP_JIT unavailable (errno \(errno))"
        } else {
            _ = munmap(ptr, 4096)
            jit = "MAP_JIT mapping allowed; executable JIT not proven"
        }
        virtualization = VPhoneNativeVM.capabilitySummary()
    }
}
