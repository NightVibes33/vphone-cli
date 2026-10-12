import Foundation
import Combine

/// A user-selected Files folder representing the USB work volume.
/// Its security scope stays alive across sequential IPSW, cloudOS, ROM and
/// upstream VM-disk operations. Other storage locations are never substituted.
@MainActor
final class VPhoneUSBWorkspace: ObservableObject {
    @Published private(set) var root: URL?
    @Published private(set) var status = "Select your USB drive once for all VM files."
    private let bookmarkKey = "vphone.usb.allfiles.workspace"
    private var scopeOpened = false

    init() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else {
                status = "USB bookmark expired. Re-select your USB folder in Files."
                return
            }
            try access(url)
        } catch {
            status = "Reconnect USB and select its folder again: \(error.localizedDescription)"
        }
    }

    func select(_ picked: URL) throws {
        // Validate the new URL before releasing the old security scope.
        let started = picked.startAccessingSecurityScopedResource()
        do {
            guard picked.isFileURL else { throw USBError.notFolder }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { throw USBError.notFolder }

            let marker = picked.appendingPathComponent(".vphone-usb-write-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: marker.path, contents: Data("ok".utf8)) else {
                throw USBError.notWritable
            }
            defer { try? FileManager.default.removeItem(at: marker) }
            let bookmark = try picked.bookmarkData()

            if scopeOpened { root?.stopAccessingSecurityScopedResource() }
            root = picked
            scopeOpened = started
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            status = "USB workspace selected: \(picked.lastPathComponent). All new firmware, ROMs and VM disk files will be written here."
        } catch {
            if started { picked.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    private func access(_ picked: URL) throws {
        let started = picked.startAccessingSecurityScopedResource()
        guard picked.isFileURL,
              FileManager.default.isReadableFile(atPath: picked.path) else {
            if started { picked.stopAccessingSecurityScopedResource() }
            throw USBError.notFolder
        }
        root = picked
        scopeOpened = started
        status = "Reconnected USB workspace: \(picked.lastPathComponent)"
    }

    func checkUsable() -> Bool {
        guard let root else { status = "Select USB storage in Files."; return false }
        let readable = FileManager.default.isReadableFile(atPath: root.path)
        if !readable { status = "USB disconnected or permission revoked. Reconnect and reselect." }
        return readable
    }

    func availableBytes() -> Int64? {
        guard let root else { return nil }
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    enum USBError: LocalizedError {
        case notFolder
        case notWritable
        var errorDescription: String? {
            switch self {
            case .notFolder:
                return "Choose the root or a folder of your external USB drive, not an IPSW file."
            case .notWritable:
                return "The selected folder cannot be written. Choose a writable USB volume formatted for large files (exFAT or APFS)."
            }
        }
    }
}
