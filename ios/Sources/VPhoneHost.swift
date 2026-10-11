import Foundation
import SwiftUI
import UIKit
import CoreVideo
import CoreGraphics
import CoreImage

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
    private var frameTimer: Timer?
    private var guestConnectTask: Task<Void, Never>?
    private var usbMonitorTask: Task<Void, Never>?
    @Published private(set) var storageStatus = "No disk selected"
    private var screenshotInFlight = false
    private var screenshotCount = 0
    @Published private(set) var guestFrameStatus = "No guest framebuffer yet"
    @Published private(set) var guestControlStatus = "vphoned not connected"

    init() { record("App started · \(ProcessInfo.processInfo.operatingSystemVersionString)") }

    func selectUSB(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            try usb.select(url)
            state = .idle
            detail = "VPhone bundle: \(usb.bundleSummary). Disk remains on external storage."
            storageStatus = "VM disk selected · direct USB access"
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

        do {
            let report = try VPhoneVMPreflight.inspect(bundleURL)
            record(report.summary)
            guard report.isReady else {
                usb.endAccess()
                state = .failed
                detail = report.summary
                return
            }
        } catch {
            usb.endAccess()
            state = .failed
            detail = "VPhone bundle validation failed: \(error.localizedDescription)"
            return
        }
        state = .starting
        detail = "Creating native PV=3 VM with upstream VPhone firmware/SEP/NVRAM."
        record("VM create requested; storage = external in-place")
        do {
            try native.prepare(withBundleURL: bundleURL)
        } catch {
            usb.endAccess()
            state = .failed
            detail = "Native VM creation failed: \(error.localizedDescription)"
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
                    self.detail = "Native VM started; awaiting actual guest boot frames."
                    self.startCapturingGuestFrames()
                    self.connectGuestDaemon()
                    self.monitorExternalStorage()
                }
                self.record(self.detail)
            }
        }
    }

    func stop(reason: String? = nil) {
        usbMonitorTask?.cancel()
        usbMonitorTask = nil
        frameTimer?.invalidate()
        frameTimer = nil
        guestConnectTask?.cancel()
        guestConnectTask = nil
        guestControlStatus = "vphoned disconnected"
        native.stop { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.usb.endAccess()
                self.state = .stopped
                self.detail = reason ?? error?.localizedDescription ?? "VM stopped"
                self.record(self.detail)
            }
        }
    }



    enum HardwareKey: String, CaseIterable {
        case home = "Home"
        case power = "Power"
        case volumeUp = "Volume +"
        case volumeDown = "Volume −"

        var usage: UInt32 {
            switch self {
            case .home: return 0x40
            case .power: return 0x30
            case .volumeUp: return 0xE9
            case .volumeDown: return 0xEA
            }
        }
    }

    func sendHardwareKey(_ key: HardwareKey) {
        guard state == .running else { return }
        if !native.sendHIDPress(withPage: 0x0C, usage: key.usage) {
            guestControlStatus = "Hardware keys require connected vphoned"
        }
    }

    func exportGuestScreenshot() -> URL? {
        guard let buffer = frames.currentFrame() else {
            guestFrameStatus = "No real guest framebuffer to export"
            return nil
        }
        let ci = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let image = context.createCGImage(ci, from: ci.extent),
              let bytes = UIImage(cgImage: image).pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VPhone-guest-screen.png")
        do {
            try bytes.write(to: url, options: .atomic)
            return url
        } catch {
            record("Failed to export guest screenshot: \(error)")
            return nil
        }
    }

    private func monitorExternalStorage() {
        usbMonitorTask?.cancel()
        usbMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.state == .running, !Task.isCancelled else { return }
                guard self.usb.isDiskAccessible else {
                    self.storageStatus = "USB disconnected — stopping guest to prevent additional writes"
                    self.record(self.storageStatus)
                    self.stop(reason: "External VM disk disconnected. Reconnect USB and reselect the folder before booting again.")
                    return
                }
            }
        }
    }

    func sendGuestTouch(phase: Int, x: Double, y: Double) {
        guard state == .running else { return }
        _ = native.sendTouch(withPhase: phase, x: x, y: y)
    }

    private func connectGuestDaemon() {
        guestConnectTask?.cancel()
        guestConnectTask = Task { [weak self] in
            for attempt in 1...30 {
                guard let self, self.state == .running, !Task.isCancelled else { return }
                let status = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    self.native.connectGuestControl { result in
                        continuation.resume(returning: result)
                    }
                }
                guard self.state == .running, !Task.isCancelled else { return }
                self.guestControlStatus = status
                if status.hasPrefix("vphoned:") {
                    self.record("Real guest vphoned VSOCK handshake established")
                    return
                }
                if attempt == 1 || attempt == 30 { self.record("Guest RPC: \(status)") }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func startCapturingGuestFrames() {
        frameTimer?.invalidate()
        screenshotInFlight = false
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .running, !self.screenshotInFlight else { return }
                self.screenshotInFlight = true
                self.native.captureRealFrame { [weak self] image in
                    Task { @MainActor in
                        guard let self else { return }
                        self.screenshotInFlight = false
                        guard self.state == .running, let image,
                              let buffer = Self.makeBuffer(image) else { return }
                        self.frames.submitGuestFrame(buffer)
                        self.screenshotCount += 1
                        if self.screenshotCount % 30 == 1 {
                            self.guestFrameStatus = "Real guest frames received: \(self.screenshotCount)"
                        }
                    }
                }
            }
        }
    }

    private static func makeBuffer(_ image: UIImage) -> CVPixelBuffer? {
        guard let cg = image.cgImage else { return nil }
        var output: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, cg.width, cg.height,
                                         kCVPixelFormatType_32BGRA, attrs, &output)
        guard status == kCVReturnSuccess, let output else { return nil }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let bitmap = CGContext(
            data: CVPixelBufferGetBaseAddress(output),
            width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(output),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue |
                        CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        bitmap.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return output
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
        Guest frames: \(screenshotCount)
        Guest RPC: \(guestControlStatus)
        Guest serial tail:
        \(native.serialLogSnapshot())
        External storage: \(storageStatus)
        Firmware: \(usb.bundleSummary)
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
