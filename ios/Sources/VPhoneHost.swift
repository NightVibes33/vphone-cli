import Foundation
import SwiftUI

@MainActor
final class VPhoneHost: ObservableObject {
    enum State: Equatable {
        case idle, starting, running, stopped, failed
        var label: String {
            switch self {
            case .idle: return "Ready for native VM launch"
            case .starting: return "Starting real virtual machine…"
            case .running: return "VM started; awaiting guest framebuffer"
            case .stopped: return "VM stopped"
            case .failed: return "VM unavailable"
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var detail = "Choose an existing vphone VM bundle. No simulated boot state is used."
    let frames = GuestFrameStore()
    let usb = ExternalVMBundle()
    let tunnel = LocalTunnel()
    let pairing = PairingRecordStore()
    let capabilities = HostCapabilities()
    private let native = VPhoneNativeVM()
    private var events: [String] = []

    init() { record("App started · \(ProcessInfo.processInfo.operatingSystemVersionString)") }

    func selectUSB(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            try usb.select(url)
            state = .idle
            detail = "VM disk selected. Disk stays on external storage."
            record("USB VM bundle opened: \(url.lastPathComponent)")
        } catch {
            state = .failed
            detail = "USB selection failed: \(error.localizedDescription)"
            record(detail)
        }
        objectWillChange.send()
    }

    func selectPairing(_ result: Result<URL, Error>) {
        do {
            try pairing.importFile(try result.get())
            record("Pairing record imported into device-only Keychain")
        } catch {
            pairing.status = "Pairing import failed: \(error.localizedDescription)"
            record("Pairing import failed (credentials not logged)")
        }
    }

    func start() {
        guard state != .starting && state != .running else { return }
        guard let bundleURL = usb.beginAccess() else {
            state = .failed
            detail = "Select an accessible VM folder (on USB or Files) first."
            return
        }

        state = .starting
        detail = "Creating a native Apple virtual machine from config.plist and disk image."
        record("VM create requested; storage = external in-place")
        var error: NSError?
        let created = native.prepare(withBundleURL: bundleURL, error: &error)
        if !created {
            usb.endAccess()
            state = .failed
            detail = "Native VM creation failed: \(error?.localizedDescription ?? "unknown failure")"
            record(detail)
            return
        }

        native.start { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.usb.endAccess()
                    self.state = .failed
                    self.detail = "Guest start failed: \(error.localizedDescription)"
                } else {
                    self.state = .running
                    self.detail = "Native VM started. Guest boot and SpringBoard are not yet verified."
                }
                self.record(self.detail)
            }
        }
    }

    func stop() {
        native.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.usb.endAccess()
                self.state = .stopped
                self.detail = error?.localizedDescription ?? "VM stopped"
                self.record(self.detail)
            }
        }
    }

    private func record(_ message: String) {
        let time = ISO8601DateFormatter().string(from: .now)
        events.append("[\(time)] \(message)")
        if events.count > 1000 { events.removeFirst(100) }
    }

    func exportDiagnostics() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VPhone-iOS-log.txt")
        let report = """
        \(events.joined(separator: "\n"))
        GPU: \(capabilities.metal)
        JIT: \(capabilities.jit)
        Virtualization: \(capabilities.virtualization)
        Tunnel: \(tunnel.status)
        Pairing imported: \(pairing.available)
        USB selected: \(usb.diskPath != nil)
        """
        try? report.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
