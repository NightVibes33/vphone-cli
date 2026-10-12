import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct VPhoneiOSApp: App {
    @StateObject private var host = VPhoneHost()

    var body: some Scene {
        WindowGroup {
            VPhoneHome()
                .environmentObject(host)
                .preferredColorScheme(.dark)
        }
    }
}

struct VPhoneHome: View {
    @EnvironmentObject private var host: VPhoneHost
    @StateObject private var firmware = VPhoneFirmwareStager()
    @State private var importingFirmwareFolder = false
    @State private var firmwareKind: VPhoneFirmwareStager.Kind = .ios
    @State private var importingFolder = false
    @State private var importingPairing = false
    @State private var importingGuestIPA = false
    @State private var shareGuestScreenshot = false
    @State private var screenshotURL: URL?
    @State private var showDiagnostics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MetalGuestView(frameStore: host.frames, onTouch: { phase, x, y in host.sendGuestTouch(phase: phase, x: x, y: y) })
                        .aspectRatio(1290.0 / 2796.0, contentMode: .fit)
                        .frame(maxHeight: 470)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 19))
                        .overlay(alignment: .bottom) {
                            if host.state != .running {
                                Text(host.state.label)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(.black.opacity(0.8), in: Capsule())
                                    .padding(12)
                            }
                        }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("VPhone · iOS 27").font(.title2.bold())
                        Text(host.detail)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(host.guestFrameStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(host.guestControlStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Text(host.usb.firmwareVersion).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let path = host.usb.diskPath {
                            Label(path, systemImage: "externaldrive")
                                .font(.caption2.monospaced())
                                .lineLimit(3)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(VPhoneHost.HardwareKey.allCases, id: \.self) { key in
                            Button(key.rawValue) { host.sendHardwareKey(key) }
                                .buttonStyle(.bordered)
                                .font(.caption2)
                                .disabled(host.state != .running)
                                .frame(maxWidth: .infinity)
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            host.start()
                        } label: {
                            Label("Boot iOS", systemImage: "power")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(host.state == .starting || host.state == .running)

                        Button("Stop") { host.stop() }
                            .buttonStyle(.bordered)
                            .disabled(host.state != .running)
                    }

                    GroupBox("External USB · direct disk") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Select VM folder on USB") { importingFolder = true }
                                .buttonStyle(.bordered)
                            Text(host.storageStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("Select a prepared upstream vphone bundle with iBoot ROM, SEP ROM, NVRAM, Disk.img and config.plist. The real disk is read from USB in place.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("iOS 27 firmware · stream to USB") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("iOS build", selection: $firmware.selection) {
                                ForEach(firmware.pairings.indices, id: \.self) { i in
                                    Text(firmware.pairings[i].iosName).tag(i)
                                }
                            }
                            .pickerStyle(.menu)
                            HStack {
                                Button("Save iOS IPSW") {
                                    firmwareKind = .ios
                                    importingFirmwareFolder = true
                                }
                                .disabled(firmware.isDownloading || firmware.pairings.isEmpty)
                                Button("Save cloudOS") {
                                    firmwareKind = .cloudOS
                                    importingFirmwareFolder = true
                                }
                                .disabled(firmware.isDownloading || firmware.pairings.isEmpty)
                                if firmware.isDownloading {
                                    Button("Cancel") { firmware.cancel() }
                                }
                            }
                            if firmware.isDownloading {
                                ProgressView(value: firmware.progress)
                            }
                            Text(firmware.status).font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text("Downloads the original upstream Apple firmware archives to USB without a full copy in iPhone storage. Firmware patching and DFU restore are separate operations.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("LocalDevVPN and pairing") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Tunnel host", text: Binding(get: { host.tunnel.host }, set: { host.tunnel.host = $0 }))
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.numbersAndPunctuation)
                                TextField("Port", text: Binding(get: { host.tunnel.port }, set: { host.tunnel.port = $0 }))
                                    .keyboardType(.numberPad)
                                    .frame(width: 80)
                            }
                            Button("Check tunnel endpoint") { host.tunnel.check() }
                                .buttonStyle(.bordered)
                            Text(host.tunnel.status).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Import pairingFile.plist") { importingPairing = true }
                                .buttonStyle(.bordered)
                            Text(host.pairing.status).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Apps inside the virtual iPhone") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button("Install IPA in guest") { importingGuestIPA = true }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(host.state != .running || host.installingGuestIPA)
                                Button("Refresh") { host.refreshGuestApps() }
                                    .buttonStyle(.bordered)
                                    .disabled(host.state != .running)
                            }
                            if host.installingGuestIPA {
                                ProgressView(value: host.guestIPAProgress)
                            }
                            Text(host.guestIPAStatus).font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(host.guestAppsStatus).font(.caption).foregroundStyle(.secondary)
                            ForEach(host.guestApps) { app in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(app.name).font(.footnote.bold())
                                        Text("\(app.id) · \(app.version)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Button("Launch") { host.launchGuestApp(app) }
                                        .buttonStyle(.bordered)
                                }
                            }
                            Text("Uses upstream vphoned port 1337, file_put streaming and ipa_install. This manages a real booted guest only; no host apps are installed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Host acceleration") {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(host.capabilities.metal, systemImage: "cpu")
                            Label(host.capabilities.jit, systemImage: "bolt")
                            Label(host.capabilities.virtualization, systemImage: "lock.shield")
                            Text("Metal renders guest frames when available. JIT mapping does not grant hardware VM access. Entitlements must be authorized by the installed provisioning profile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Save real guest screenshot") {
                        screenshotURL = host.exportGuestScreenshot()
                        shareGuestScreenshot = screenshotURL != nil
                    }
                    .font(.footnote)
                    .disabled(host.state != .running)

                    Button("Export diagnostics and guest serial log") { showDiagnostics = true }
                        .font(.footnote)
                }
                .padding()
            }
            .navigationTitle("VPhone")
            .sheet(isPresented: $showDiagnostics) {
                ShareSheet(items: [host.exportDiagnostics()])
            }
            .sheet(isPresented: $shareGuestScreenshot) {
                if let screenshotURL {
                    ShareSheet(items: [screenshotURL])
                }
            }
            .fileImporter(isPresented: $importingFirmwareFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder):
                    firmware.download(firmwareKind, folder: folder)
                case .failure(_):
                    break
                }
            }
            .fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder]) { result in
                host.selectUSB(result)
            }
            .fileImporter(isPresented: $importingGuestIPA, allowedContentTypes: [UTType(filenameExtension: "ipa") ?? .data]) { result in
                host.installGuestIPA(result)
            }
            .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.data]) { result in
                host.selectPairing(result)
            }

        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
