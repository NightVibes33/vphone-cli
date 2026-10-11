import Foundation

/// Runs the real upstream VPhone bundle manifest through its native Codable loader.
/// Does not replace firmware patch/restore or claim that iOS has VMM permission.
struct VPhoneVMPreflight {
    let missing: [String]
    let bundle: VPhoneBundle
    let restore: VPhoneRestoreInfo?

    var isReady: Bool { missing.isEmpty }

    var summary: String {
        if !missing.isEmpty {
            return "Incomplete VPhone guest: missing \(missing.joined(separator: ", ")). Use a restored VPhone bundle (not a raw IPSW)."
        }
        return "VPhone guest assets verified: \(bundle.name), \(bundle.manifest.cpuCount) cores, \(bundle.manifest.memorySize / 1048576) MB; \(restore?.ios.version ?? "unknown iOS"). Apple VM authorization still required."
    }

    static func inspect(_ url: URL) throws -> Self {
        let bundle = try VPhoneBundle.load(at: url)
        let fm = FileManager.default
        let manifest = bundle.manifest
        var missing: [String] = []

        func require(_ name: String?, description: String) {
            guard let name, !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains(".."),
                  !name.contains("\\") else {
                missing.append(description)
                return
            }
            let candidate = url.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) {
                missing.append(description)
            }
        }

        require(manifest.diskImage, description: "guest disk")
        require(manifest.nvramStorage, description: "NVRAM")
        require(manifest.sepStorage, description: "SEP storage")
        require(manifest.romImages?.avpBooter, description: "iBoot/AVP ROM")
        require(manifest.romImages?.avpSEPBooter, description: "SEP ROM")
        return .init(missing: missing, bundle: bundle,
                     restore: VPhoneRestoreInfo.load(fromBundle: bundle))
    }
}
