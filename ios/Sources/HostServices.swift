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

    // Bookmark the exact URL the Files picker authorized (the USB root or a
    // selected folder). Derived subfolders do not necessarily have their own
    // security-scope entitlement.
    private let bookmarkKey = "vphone.usb.folder.bookmark"
    private let relativePathKey = "vphone.usb.bundle.relativePath"
    private var bookmarked: Data?
    private var selectedURL: URL?
    private var relativeBundlePath = ""
    private var activeScopeURL: URL?
    private var acquiredAccess = false
    private var activeBundleURL: URL?

    var isDiskAccessible: Bool {
        guard let bundleURL = activeBundleURL,
              let diskPath else { return false }
        return FileManager.default.isReadableFile(
            atPath: bundleURL.appendingPathComponent("config.plist").path
        ) && FileManager.default.isReadableFile(atPath: diskPath)
    }

    init() {
        bookmarked = UserDefaults.standard.data(forKey: bookmarkKey)
        relativeBundlePath = UserDefaults.standard.string(forKey: relativePathKey) ?? ""
        if let bookmarked {
            var stale = false
            if let root = try? URL(resolvingBookmarkData: bookmarked, options: [],
                                   relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
                selectedURL = root
                let bundle = relativeBundlePath.isEmpty ? root
                    : root.appendingPathComponent(relativeBundlePath, isDirectory: true)
                let scope = root.startAccessingSecurityScopedResource()
                if let loaded = try? VPhoneBundle.load(at: bundle) {
                    diskPath = bundle.url.appendingPathComponent(loaded.manifest.diskImage).path
                    firmwareVersion = Self.versionSummary(
                        VPhoneRestoreInfo.load(fromBundle: loaded))
                    bundleSummary = Self.bundleSummary(loaded, firmwareVersion: firmwareVersion)
                }
                if scope { root.stopAccessingSecurityScopedResource() }
            }
        }
    }

    func select(_ pickerURL: URL) throws {
        let fm = FileManager.default
        let scoped = pickerURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickerURL.stopAccessingSecurityScopedResource() } }

        guard pickerURL.isFileURL else {
            throw VPhoneStorageError.unavailableFolder
        }
        var directoryFlag: ObjCBool = false
        guard fm.fileExists(atPath: pickerURL.path, isDirectory: &directoryFlag),
              directoryFlag.boolValue else {
            throw VPhoneStorageError.unavailableFolder
        }

        let selected = try Self.findBundle(in: pickerURL)
        let bundle = try VPhoneBundle.load(at: selected.url)
        let diskName = bundle.manifest.diskImage
        guard Self.safeRelativeFileName(diskName) else {
            throw VPhoneStorageError.invalidImagePath
        }
        let disk = selected.url.appendingPathComponent(diskName)
        guard fm.isReadableFile(atPath: disk.path) else {
            throw VPhoneStorageError.missingDisk(disk.lastPathComponent)
        }

        // Commit the selection only after all validation succeeds. An invalid
        // Files selection must not overwrite the previously valid bookmark.
        let bookmark = try pickerURL.bookmarkData()
        selectedURL = pickerURL
        relativeBundlePath = selected.relativePath
        bookmarked = bookmark
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
        UserDefaults.standard.set(selected.relativePath, forKey: relativePathKey)
        diskPath = disk.path
        firmwareVersion = Self.versionSummary(VPhoneRestoreInfo.load(fromBundle: bundle))
        bundleSummary = Self.bundleSummary(bundle, firmwareVersion: firmwareVersion)
    }

    func beginAccess() -> URL? {
        if let activeBundleURL { return activeBundleURL }
        guard let bookmarked else { return nil }

        let root: URL
        if let selectedURL {
            root = selectedURL
        } else {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: bookmarked, options: [],
                                          relativeTo: nil, bookmarkDataIsStale: &stale),
                  !stale else { return nil }
            root = resolved
        }

        let scope = root.startAccessingSecurityScopedResource()
        let bundleURL = relativeBundlePath.isEmpty ? root
            : root.appendingPathComponent(relativeBundlePath, isDirectory: true)
        guard let bundle = try? VPhoneBundle.load(at: bundleURL),
              Self.safeRelativeFileName(bundle.manifest.diskImage),
              FileManager.default.isReadableFile(
                atPath: bundleURL.appendingPathComponent(bundle.manifest.diskImage).path) else {
            if scope { root.stopAccessingSecurityScopedResource() }
            return nil
        }
        // Keep the actual root scope open for the entire VM lifetime. The
        // resolved bundle path remains nested under that authorized root.
        activeScopeURL = root
        activeBundleURL = bundleURL
        acquiredAccess = scope
        diskPath = bundleURL.appendingPathComponent(bundle.manifest.diskImage).path
        return bundleURL
    }

    func endAccess() {
        if acquiredAccess { activeScopeURL?.stopAccessingSecurityScopedResource() }
        activeScopeURL = nil
        activeBundleURL = nil
        acquiredAccess = false
    }

    private static func versionSummary(_ restore: VPhoneRestoreInfo?) -> String {
        guard let restore else { return "Firmware restore information not recorded" }
        return "iOS \(restore.ios.version) (\(restore.ios.build)) + cloudOS \(restore.cloudOS.version)"
    }

    private static func bundleSummary(_ bundle: VPhoneBundle,
                                      firmwareVersion: String) -> String {
        "\(bundle.name) · \(bundle.manifest.cpuCount) CPU · \(bundle.manifest.memorySize / (1024 * 1024)) MB · \(firmwareVersion)"
    }

    private static func safeRelativeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("..")
            && !name.contains("\\")
    }

    private struct Candidate {
        let url: URL
        let relativePath: String
    }

    /// Accept a VM folder directly, or discover a single immediate child with
    /// config.plist when the user selected a USB root or a parent directory.
    /// Never recursively crawl an entire USB disk or guess between multiple VMs.
    private static func findBundle(in root: URL) throws -> Candidate {
        let fm = FileManager.default
        if fm.isReadableFile(atPath: root.appendingPathComponent("config.plist").path) {
            return Candidate(url: root, relativePath: "")
        }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            throw VPhoneStorageError.directoryCannotBeListed(error.localizedDescription)
        }

        let folders = entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        let candidates = folders.filter {
            fm.isReadableFile(atPath: $0.appendingPathComponent("config.plist").path)
        }
        if candidates.count == 1, let item = candidates.first {
            return Candidate(url: item, relativePath: item.lastPathComponent)
        }
        if candidates.count > 1 {
            throw VPhoneStorageError.multipleVMFolders(candidates.map(\.lastPathComponent))
        }

        let localFirmware = entries.filter {
            ["ipsw", "partial"].contains($0.pathExtension.lowercased())
        }.map(\.lastPathComponent)
        // The app also saves firmware under a Files-visible Firmware directory.
        // Detect it when selecting the parent, without scanning an entire drive.
        let firmwareDirectories = folders.filter {
            $0.lastPathComponent.lowercased() == "firmware"
        }
        let nestedFirmware = firmwareDirectories.flatMap { directory in
            ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["ipsw", "partial"].contains($0.pathExtension.lowercased()) }
                .map(\.lastPathComponent)
        }
        let firmwareNames = localFirmware + nestedFirmware
        if !firmwareNames.isEmpty {
            throw VPhoneStorageError.firmwareOnly(firmwareNames)
        }

        let foldersWithDisk = folders.filter {
            fm.fileExists(atPath: $0.appendingPathComponent("Disk.img").path)
        }
        if !foldersWithDisk.isEmpty {
            throw VPhoneStorageError.diskWithoutManifest(foldersWithDisk.map(\.lastPathComponent))
        }

        throw VPhoneStorageError.noVMFolder(entries.prefix(6).map(\.lastPathComponent))
    }
}

enum VPhoneStorageError: LocalizedError {
    case invalidImagePath
    case missingDisk(String)
    case unavailableFolder
    case directoryCannotBeListed(String)
    case multipleVMFolders([String])
    case firmwareOnly([String])
    case diskWithoutManifest([String])
    case noVMFolder([String])

    var errorDescription: String? {
        switch self {
        case .invalidImagePath:
            return "The VM disk path escapes the selected folder."
        case let .missingDisk(name):
            return "The selected VM has config.plist but its disk \(name) is missing or inaccessible."
        case .unavailableFolder:
            return "The selected Files folder is no longer accessible. Reconnect USB and select the VM directory again."
        case let .directoryCannotBeListed(message):
            return "Cannot read this Files/USB directory: \(message). Check storage permissions or reconnect the drive."
        case let .multipleVMFolders(names):
            return "More than one prepared VPhone VM was found (\(names.prefix(4).joined(separator: ", "))). Select the specific VM folder containing config.plist."
        case let .firmwareOnly(names):
            return "Found firmware download files (\(names.prefix(3).joined(separator: ", "))), but no prepared VPhone VM. IPSW/cloudOS downloads are not directly bootable. This app still requires a restored VM folder with config.plist, Disk.img, NVRAM and ROM/SEP files. Prepare/restore the VM with upstream VPhone on a supported host first."
        case let .diskWithoutManifest(names):
            return "Found Disk.img inside \(names.prefix(3).joined(separator: ", ")) but no config.plist. The disk alone is not a bootable VPhone VM. Select a complete prepared bundle."
        case let .noVMFolder(names):
            let contents = names.isEmpty ? "This folder is empty." : "Visible items: \(names.joined(separator: ", "))."
            return "No VPhone config.plist found in this folder or its immediate subfolders. \(contents) Select the folder containing a prepared config.plist and Disk.img, not just the downloaded IPSW."
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
