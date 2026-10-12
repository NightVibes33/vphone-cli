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

        // This app launches a real iOS 27 guest, not an arbitrary IPSW.
        // A raw IPSW is not a prepared VM; require the restore provenance
        // recorded by upstream VPhone or derived from its restore manifests.
        let restored = VPhoneRestoreInfo.load(fromBundle: bundle)
        if let restored {
            if !restored.ios.version.hasPrefix("27.") {
                missing.append("iOS 27 restore (found iOS \(restored.ios.version))")
            }
        } else {
            missing.append("iOS 27 restore version metadata (restore-info.json)")
        }

        // Disk existence alone is insufficient for a valid restored guest.
        if bundle.diskSizeBytes <= 0 {
            missing.append("non-empty restored VM disk image")
        }

        return .init(missing: missing, bundle: bundle, restore: restored)
    }
}
