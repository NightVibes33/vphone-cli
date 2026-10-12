import Foundation
import Combine
import CryptoKit

/// Creates the real upstream VM bundle ON USB, without staging the IPSWs,
/// boot ROMs, or sparse Disk.img on the iPhone.
@MainActor
final class VPhoneBundleProvisioner: ObservableObject {
    @Published private(set) var status = "Select the USB folder containing Firmware and extracted host ROMs."
    @Published private(set) var createdBundleURL: URL?

    func createBundle(onUSB root: URL, pairing: VPhoneFirmwarePairing) -> URL? {
        let scope = root.startAccessingSecurityScopedResource()
        defer { if scope { root.stopAccessingSecurityScopedResource() } }
        do {
            guard root.isFileURL else { throw ProvisionError.invalidUSB }
            let fm = FileManager.default
            let iphone = "\(pairing.iosName.replacingOccurrences(of: " ", with: "-"))-iPhone17,3.ipsw"
            let cloud = "\(pairing.cloudosName.replacingOccurrences(of: " ", with: "-"))-cloudOS.ipsw"
            let roots = [root, root.appendingPathComponent("Firmware", isDirectory: true)]
            let iosSource = roots.map { $0.appendingPathComponent(iphone) }.first {
                fm.isReadableFile(atPath: $0.path)
            }
            let cloudSource = roots.map { $0.appendingPathComponent(cloud) }.first {
                fm.isReadableFile(atPath: $0.path)
            }
            guard let iosSource, let cloudSource else {
                throw ProvisionError.missingIPSW([iosSource == nil ? iphone : nil,
                                                  cloudSource == nil ? cloud : nil].compactMap { $0 })
            }

            // iOS Files extracts VPhone-macOS-host-ROMs.zip into a folder of
            // the same name. No ROMs are ever stored under On My iPhone.
            let romDirectories = [
                root.appendingPathComponent("VPhone-macOS-host-ROMs", isDirectory: true),
                root.appendingPathComponent("VPhoneHostROMs", isDirectory: true),
                root
            ]
            guard let romFolder = romDirectories.first(where: { folder in
                fm.isReadableFile(atPath: folder.appendingPathComponent("AVPBooter.vresearch1.bin").path)
                    && fm.isReadableFile(atPath: folder.appendingPathComponent("AVPSEPBooter.vresearch1.bin").path)
            }) else {
                throw ProvisionError.missingROMs
            }
            // Only accept the exact two unmodified ROMs from the runner ZIP.
            try validateROMs(in: romFolder)

            let libraryRoot = root.appendingPathComponent("VMs", isDirectory: true)
            try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
            let vmName = "vphone-iOS27-\(pairing.iosName.replacingOccurrences(of: " ", with: "-"))"
                .replacingOccurrences(of: "/", with: "-")
            let spec = VPhoneBundleOps.NewBundleSpec(
                name: vmName, cpuCount: 4, memoryMB: 3072, diskSizeGB: 32,
                romSource: romFolder.appendingPathComponent("AVPBooter.vresearch1.bin"),
                sepromSource: romFolder.appendingPathComponent("AVPSEPBooter.vresearch1.bin"))
            let bundle = try VPhoneBundleOps.create(spec, in: VPhoneLibrary(root: libraryRoot))
            let stage = FirmwareStage(
                format: 1,
                status: "unrestored",
                iphoneIPSW: "../../" + relativePath(iosSource, root: root),
                cloudOSIPSW: "../../" + relativePath(cloudSource, root: root),
                iosVersion: pairing.iosName, cloudOSVersion: pairing.cloudosName,
                instructions: "Run upstream fw prepare/patch, DFU restore and CFW installation before booting.")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(stage).write(to:
                    bundle.url.appendingPathComponent("firmware-stage.json"), options: .atomic)
            } catch {
                try? fm.removeItem(at: bundle.url)
                throw error
            }
            createdBundleURL = bundle.url
            status = "USB bundle created: VMs/\(vmName). Uses original upstream config.plist and Disk.img. No firmware or VM data copied into the iPhone container. UNRESTORED: it still requires DFU restore and host VM permission before boot."
            return bundle.url
        } catch {
            status = "USB VM creation failed: \(error.localizedDescription)"
            return nil
        }
    }

    private func validateROMs(in folder: URL) throws {
        let checksumURL = folder.appendingPathComponent("SHA256SUMS")
        guard let checksums = try? String(contentsOf: checksumURL, encoding: .utf8) else {
            throw ProvisionError.missingChecksums
        }
        let required = ["AVPBooter.vresearch1.bin", "AVPSEPBooter.vresearch1.bin"]
        for name in required {
            guard let checksumLine = checksums.split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { $0.hasSuffix(name) }),
                  let expected = checksumLine.split(whereSeparator: \.isWhitespace).first,
                  expected.count == 64,
                  expected.allSatisfy({ $0.isHexDigit }) else {
                throw ProvisionError.missingChecksums
            }
            let url = folder.appendingPathComponent(name)
            let fd = try FileHandle(forReadingFrom: url)
            defer { try? fd.close() }
            var sha = SHA256()
            var size = 0
            while let data = try fd.read(upToCount: 128 * 1024), !data.isEmpty {
                sha.update(data: data)
                size += data.count
                guard size < 128 * 1024 * 1024 else { throw ProvisionError.invalidROM(name) }
            }
            guard size > 1024 else { throw ProvisionError.invalidROM(name) }
            let actual = sha.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual.caseInsensitiveCompare(String(expected)) == .orderedSame else {
                throw ProvisionError.checksumMismatch(name)
            }
        }
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let base = root.standardizedFileURL.path
        let file = url.standardizedFileURL.path
        guard file.hasPrefix(base + "/") else { return url.lastPathComponent }
        return String(file.dropFirst(base.count + 1))
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
        case invalidUSB
        case missingIPSW([String])
        case missingROMs
        case missingChecksums
        case invalidROM(String)
        case checksumMismatch(String)
        var errorDescription: String? {
            switch self {
            case .invalidUSB:
                return "Select an accessible external USB folder in Files."
            case .missingIPSW(let files):
                return "Firmware not found on the USB volume: \(files.joined(separator: ", ")). Download both directly to USB or move existing iPhone downloads there using Files."
            case .missingROMs:
                return "Host ROMs not found on USB. Download the macOS runner artifact to USB and tap its ZIP in Files to extract VPhone-macOS-host-ROMs/ with both .bin files."
            case .missingChecksums:
                return "Missing SHA256SUMS in the extracted ROM artifact folder."
            case .invalidROM(let name):
                return "Unexpected host ROM file length: \(name)"
            case .checksumMismatch(let name):
                return "Host ROM SHA-256 mismatch: \(name). Re-extract the runner artifact on USB."
            }
        }
    }
}
