import Foundation
import Combine

/// The upstream VPhoneBundleOps.create layout is the first stage of vm create.
/// This does not patch, DFU-restore, or activate the guest. It does not produce
/// restore-info.json because no restore has taken place.
@MainActor
final class VPhoneBundleProvisioner: ObservableObject {
    enum Destination {
        case onDevice
        case selectedFolder(URL)
    }
    enum ROM: String, CaseIterable {
        case avpBooter = "AVPBooter.vresearch1.bin"
        case avpSEPBooter = "AVPSEPBooter.vresearch1.bin"
    }

    @Published private(set) var status = "Upstream VM bundle: not prepared"
    @Published private(set) var createdBundleURL: URL?
    @Published private(set) var readyROMs: Set<String> = []

    private var romStore: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VPhoneHostROMs", isDirectory: true)
    }
    private var documentRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() { refreshROMs() }

    func refreshROMs() {
        readyROMs = Set(ROM.allCases.filter { rom in
            let url = romStore.appendingPathComponent(rom.rawValue)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            return bytes > 0
        }.map(\.rawValue))
    }

    func importROM(_ result: Result<URL, Error>, as rom: ROM) {
        do {
            let source = try result.get()
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 1024 && size < 128 * 1024 * 1024 else {
                throw ProvisionError.invalidROM
            }
            try FileManager.default.createDirectory(at: romStore, withIntermediateDirectories: true)
            let target = romStore.appendingPathComponent(rom.rawValue)
            let temporary = romStore.appendingPathComponent(".rom-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: temporary)
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.moveItem(at: temporary, to: target)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            refreshROMs()
            status = "Imported \(rom.rawValue) from Files. VM firmware restore is still required."
        } catch {
            status = "Cannot import \(rom.rawValue): \(error.localizedDescription)"
        }
    }

    func createBundle(destination: Destination, pairing: VPhoneFirmwarePairing) -> URL? {
        let root: URL
        switch destination {
        case .onDevice:
            root = documentRoot
        case .selectedFolder(let url):
            root = url
        }
        let scope: Bool
        switch destination {
        case .onDevice: scope = false
        case .selectedFolder: scope = root.startAccessingSecurityScopedResource()
        }
        defer { if scope { root.stopAccessingSecurityScopedResource() } }

        do {
            refreshROMs()
            guard readyROMs.contains(ROM.avpBooter.rawValue),
                  readyROMs.contains(ROM.avpSEPBooter.rawValue) else {
                throw ProvisionError.missingHostROMs
            }
            let firmwareFolder = root.appendingPathComponent("Firmware", isDirectory: true)
            let searchRoots = [root, firmwareFolder]
            let iphoneFileName = "\(pairing.iosName.replacingOccurrences(of: " ", with: "-"))-iPhone17,3.ipsw"
            let cloudFileName = "\(pairing.cloudosName.replacingOccurrences(of: " ", with: "-"))-cloudOS.ipsw"
            let iosSource = searchRoots.map { $0.appendingPathComponent(iphoneFileName) }
                .first { FileManager.default.isReadableFile(atPath: $0.path) }
            let cloudSource = searchRoots.map { $0.appendingPathComponent(cloudFileName) }
                .first { FileManager.default.isReadableFile(atPath: $0.path) }
            guard let iosSource, let cloudSource else {
                throw ProvisionError.missingFirmware(
                    iphone: iosSource == nil ? iphoneFileName : nil,
                    cloud: cloudSource == nil ? cloudFileName : nil)
            }
            let vmRoot = root.appendingPathComponent("VMs", isDirectory: true)
            try FileManager.default.createDirectory(at: vmRoot, withIntermediateDirectories: true)
            let name = "vphone-iOS27-\(pairing.iosName.replacingOccurrences(of: " ", with: "-"))"
                .replacingOccurrences(of: "/", with: "-")
            let library = VPhoneLibrary(root: vmRoot)
            let spec = VPhoneBundleOps.NewBundleSpec(
                name: name,
                cpuCount: 4,
                memoryMB: 3072,
                diskSizeGB: 32,
                romSource: romStore.appendingPathComponent(ROM.avpBooter.rawValue),
                sepromSource: romStore.appendingPathComponent(ROM.avpSEPBooter.rawValue))
            let bundle = try VPhoneBundleOps.create(spec, in: library)

            // Paths refer to the ORIGINAL downloaded firmware outside Disk.img:
            // no IPSW archive is duplicated in VM storage.
            let stage = FirmwareStage(
                format: 1,
                status: "unrestored",
                iphoneIPSW: "../../" + relativeSource(iosSource, root: root),
                cloudOSIPSW: "../../" + relativeSource(cloudSource, root: root),
                iosVersion: pairing.iosName,
                cloudOSVersion: pairing.cloudosName,
                instructions: "Run upstream fw prepare/patch, DFU restore and custom firmware install before booting. No restore has occurred.")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(stage).write(
                    to: bundle.url.appendingPathComponent("firmware-stage.json"), options: .atomic)
            } catch {
                // Do not leave an orphaned disk or a manifest that looks ready.
                try? FileManager.default.removeItem(at: bundle.url)
                throw error
            }
            createdBundleURL = bundle.url
            status = "Created upstream VPhone VM layout at \(bundle.url.lastPathComponent), with config.plist, a sparse 32 GB Disk.img, 512 KB SEPStorage and imported host ROMs. Firmware is linked by relative paths, not copied. Status: UNRESTORED. DFU restore and PV=3 authorization are still required."
            return bundle.url
        } catch {
            status = "VM bundle creation failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func relativeSource(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private struct FirmwareStage: Codable {
        let format: Int
        let status: String
        let iphoneIPSW: String
        let cloudOSIPSW: String
        let iosVersion: String
        let cloudOSVersion: String
        let instructions: String
    }

    private enum ProvisionError: LocalizedError {
        case missingHostROMs
        case missingFirmware(iphone: String?, cloud: String?)
        case invalidROM

        var errorDescription: String? {
            switch self {
            case .missingHostROMs:
                return "Upstream VM creation requires both research host ROMs (AVPBooter.vresearch1.bin and AVPSEPBooter.vresearch1.bin), which upstream obtains from the macOS Virtualization framework. Import these real files first; the downloaded IPSWs do not contain them."
            case let .missingFirmware(iphone, cloud):
                return "Missing downloaded firmware in the chosen storage folder: \([iphone, cloud].compactMap { $0 }.joined(separator: ", ")). Select the storage location holding both files. Firmware on the phone is not silently copied to USB."
            case .invalidROM:
                return "ROM is empty, truncated or unexpectedly large. Import the upstream AVP boot ROM file, not an IPSW."
            }
        }
    }
}

