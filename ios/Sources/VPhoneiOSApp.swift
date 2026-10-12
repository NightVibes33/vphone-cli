import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main
struct VPhoneiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var host = VPhoneHost()

    var body: some Scene {
        WindowGroup {
            VPhoneHome()
                .environmentObject(host)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    host.handleScenePhase(phase)
                }
        }
    }
}

struct VPhoneHome: View {
    @EnvironmentObject private var host: VPhoneHost
    @StateObject private var firmware = VPhoneFirmwareStager()
    @StateObject private var provisioner = VPhoneBundleProvisioner()
    @StateObject private var romDownload = VPhoneROMArtifactDownloader()
    @State private var githubActionsToken = ""
    @State private var importingROMArtifactUSBFolder = false
    @State private var importingFirmwareFolder = false
    @State private var importingVMStorageFolder = false
    @State private var firmwareKind: VPhoneFirmwareStager.Kind = .ios
    @State private var importingFolder = false
    @State private var importingPairing = false
    @State private var importingGuestIPA = false
    @State private var shareGuestScreenshot = false
    @State private var screenshotURL: URL?
    @State private var showDiagnostics = false

    private func startFirmwareDownload(_ kind: VPhoneFirmwareStager.Kind) {
        firmwareKind = kind
        importingFirmwareFolder = true
    }

    private func prepareFromDownloadedFirmware(onUSB folder: URL) {
        guard firmware.pairings.indices.contains(firmware.selection) else { return }
        if provisioner.createBundle(onUSB: folder,
                                    pairing: firmware.pairings[firmware.selection]) != nil {
            // The picker authorized the root; VPhone's VM lives under /VMs.
            host.selectUSB(.success(folder))
        }
    }

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
                        Text(host.guestBootStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
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
                        .disabled(host.state == .starting || host.state == .running || host.state == .stopping || host.state == .stopUnconfirmed)

                        Button("Stop") { host.stop() }
                            .buttonStyle(.bordered)
                            .disabled(host.state != .running && host.state != .stopUnconfirmed)
                    }

                    GroupBox("VM disk · USB storage") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Select existing VM folder in Files") { importingFolder = true }
                                .buttonStyle(.bordered)
                                .disabled(host.state == .running || host.state == .starting || host.state == .stopping || host.state == .stopUnconfirmed)
                            Text(host.storageStatus).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if host.state == .failed {
                                Text(host.detail)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                            }
                            if !firmware.onDeviceFiles.isEmpty && host.usb.diskPath == nil {
                                Text("Existing iPhone downloads: \(firmware.onDeviceFiles.count). To use USB-only storage, move those old IPSWs onto your drive with Files; VPhone will not copy them automatically.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("Select the external USB folder containing VMs. Keep it connected until the guest is fully stopped.")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("The VM folder requires a generated config.plist and Disk.img plus iBoot, NVRAM and SEP assets. The app can download IPSWs but does not yet perform the required iOS 27 guest restore.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Firmware files · download to USB") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("All new iOS IPSW and cloudOS downloads go directly to the USB folder you select in Files. No iPhone Documents or Caches copy.")
                                .font(.caption).foregroundStyle(.secondary)

                            Picker("iOS build", selection: $firmware.selection) {
                                ForEach(firmware.pairings.indices, id: \.self) { i in
                                    Text(firmware.pairings[i].iosName).tag(i)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(firmware.isDownloading)

                            HStack {
                                Button("Download iOS IPSW") {
                                    startFirmwareDownload(.ios)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(firmware.isDownloading || firmware.pairings.isEmpty)

                                Button("Download cloudOS") {
                                    startFirmwareDownload(.cloudOS)
                                }
                                .buttonStyle(.bordered)
                                .disabled(firmware.isDownloading || firmware.pairings.isEmpty)

                                if firmware.isDownloading {
                                    Button("Cancel") { firmware.cancel() }
                                }
                            }

                            if firmware.isDownloading {
                                ProgressView(value: firmware.progress)
                            }
                            Text(firmware.status)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)

                            HStack {
                                Text("On-device downloads")
                                    .font(.subheadline.bold())
                                Spacer()
                                Button("Refresh") { firmware.refreshOnDeviceFiles() }
                                    .font(.caption)
                            }
                            if firmware.onDeviceFiles.isEmpty {
                                Text("No files downloaded to this iPhone yet.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(firmware.onDeviceFiles, id: \.path) { file in
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc.zipper")
                                        Text(file.lastPathComponent)
                                            .font(.caption.monospaced())
                                            .lineLimit(2)
                                        Spacer(minLength: 4)
                                        ShareLink(item: file) {
                                            Image(systemName: "square.and.arrow.up")
                                        }
                                        .accessibilityLabel("Share \(file.lastPathComponent)")
                                    }
                                }
                            }
                            Text("Fast IPSW mode uses up to 4 parallel Apple CDN connections when range downloads are supported. Finished 32 MB blocks are checkpointed for resume. CloudOS and unsupported servers use compatible single-stream mode.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Partial downloads stay on the selected USB folder. Older files already downloaded to On My iPhone are not automatically copied; use Files to move them to USB if needed. Firmware downloads do not restore the guest.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Host ROM artifact · macOS runner → USB") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("GitHub Actions successfully collected the genuine Apple Virtualization.framework research boot ROMs on macOS 15. The archive is downloaded directly to your chosen USB folder, not the iPhone.")
                                .font(.caption).foregroundStyle(.secondary)

                            SecureField("GitHub token (Actions: Read)", text: $githubActionsToken)
                                .textContentType(.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.caption)
                            Text("A fine-grained GitHub token with repository Actions: Read is needed to download Actions artifacts. It is kept only in memory, never stored in the app or sent to the signed artifact host.")
                                .font(.caption2).foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                Button("Download ROM artifact to USB") {
                                    importingROMArtifactUSBFolder = true
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(romDownload.downloading)

                                if romDownload.downloading {
                                    Button("Cancel") { romDownload.cancel() }
                                        .buttonStyle(.bordered)
                                }
                            }

                            if romDownload.downloading {
                                ProgressView(value: romDownload.fraction)
                            }
                            Text(romDownload.status)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Link("View ROM artifact in GitHub Actions",
                                 destination: URL(string: "https://github.com/NightVibes33/vphone-cli/actions/workflows/vphone-host-roms.yml")!)
                                .font(.caption)

                            Text("After downloading, use Files on the USB drive to extract VPhone-macOS-host-ROMs.zip. The app then finds both ROMs and SHA256SUMS inside the extracted folder on USB.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Create upstream VM · USB only") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Uses the actual upstream VPhoneBundleOps.create, the iOS/cloudOS IPSWs and the verified ROMs already on the same USB drive. The VM disk, SEP files and config.plist are created on USB.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Create VM bundle on USB") {
                                importingVMStorageFolder = true
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(firmware.isDownloading || firmware.pairings.isEmpty ||
                                      romDownload.downloading)
                            Text(provisioner.status)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Text("Upstream bundle creation is only the first stage. DFU restoration, firmware patching and private PV=3 virtualization authorization remain unavailable on a normal SideStore-signed iPhone. An unrestored disk cannot boot iOS.")
                                .font(.caption)
                                .foregroundStyle(.orange)
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
            .fileImporter(isPresented: $importingROMArtifactUSBFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result {
                    romDownload.fetch(to: folder, token: githubActionsToken)
                }
            }
            .fileImporter(isPresented: $importingVMStorageFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(folder) = result {
                    prepareFromDownloadedFirmware(onUSB: folder)
                }
            }
            .fileImporter(isPresented: $importingFirmwareFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder):
                    firmware.download(firmwareKind, destination: .chosenFolder(folder))
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
            .fullScreenCover(
                isPresented: Binding(
                    get: { host.guestFullscreenPresented },
                    set: { if !$0 { host.closeGuestFullscreen() } }
                )
            ) {
                VPhoneGuestFullscreen()
                    .environmentObject(host)
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
