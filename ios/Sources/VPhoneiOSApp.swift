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
    @StateObject private var workspace = VPhoneUSBWorkspace()
    @State private var choosingUSBWorkspace = false
    @State private var startAllWhenUSBChosen = false
    @State private var usbSetupStatus = "Download both IPSWs and ROMs, then create the 32 GiB disk directly on USB."
    @State private var setupPhase: USBSetupPhase = .idle

    private enum USBSetupPhase {
        case idle, ios, cloudOS, rom, disk, done, failed
    }
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
        if let root = workspace.root, workspace.checkUsable() {
            firmware.download(kind, destination: .chosenFolder(root))
        } else {
            importingFirmwareFolder = true
        }
    }

    private func prepareFromDownloadedFirmware(onUSB folder: URL) async {
        guard firmware.pairings.indices.contains(firmware.selection) else { return }
        if await provisioner.createBundle(onUSB: folder,
                                          pairing: firmware.pairings[firmware.selection]) != nil {
            host.selectUSB(.success(folder))
        }
    }

    private func startAllUSBFiles() {
        if workspace.root == nil {
            startAllWhenUSBChosen = true
            choosingUSBWorkspace = true
        } else {
            beginAllUSBFiles()
        }
    }

    private func beginAllUSBFiles() {
        guard !firmware.isDownloading && !romDownload.downloading,
              firmware.pairings.indices.contains(firmware.selection),
              workspace.checkUsable(), workspace.root != nil else {
            usbSetupStatus = workspace.status
            setupPhase = .failed
            return
        }
        // All four outputs use one and the same selected USB scope. Nothing
        // is downloaded to Documents, tmp, or a different Files provider URL.
        setupPhase = .ios
        advanceAllUSBFiles()
    }

    private func existingUSBFile(_ name: String, in root: URL) -> URL? {
        [root, root.appendingPathComponent("Firmware", isDirectory: true)]
            .map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private func advanceAllUSBFiles() {
        guard let root = workspace.root, workspace.checkUsable(),
              firmware.pairings.indices.contains(firmware.selection) else {
            usbSetupStatus = "USB was disconnected or its folder access expired. Reconnect and choose it again."
            setupPhase = .failed
            return
        }
        let selected = firmware.pairings[firmware.selection]
        switch setupPhase {
        case .ios:
            let name = "\(selected.iosName.replacingOccurrences(of: " ", with: "-"))-iPhone17,3.ipsw"
            if existingUSBFile(name, in: root) != nil {
                usbSetupStatus = "Existing iOS IPSW found on USB. Checking cloudOS…"
                setupPhase = .cloudOS
                advanceAllUSBFiles()
            } else {
                usbSetupStatus = "Step 1/4: iOS 27 IPSW → USB"
                firmware.download(.ios, destination: .chosenFolder(root))
            }
        case .cloudOS:
            let name = "\(selected.cloudosName.replacingOccurrences(of: " ", with: "-"))-cloudOS.ipsw"
            if existingUSBFile(name, in: root) != nil {
                usbSetupStatus = "Existing cloudOS IPSW found on USB. Checking research ROMs…"
                setupPhase = .rom
                advanceAllUSBFiles()
            } else {
                usbSetupStatus = "Step 2/4: cloudOS IPSW → USB"
                firmware.download(.cloudOS, destination: .chosenFolder(root))
            }
        case .rom:
            let romRoot = root.appendingPathComponent("VPhone-macOS-host-ROMs", isDirectory: true)
            let bin = romRoot.appendingPathComponent("AVPBooter.vresearch1.bin")
            let sep = romRoot.appendingPathComponent("AVPSEPBooter.vresearch1.bin")
            if FileManager.default.isReadableFile(atPath: bin.path) &&
               FileManager.default.isReadableFile(atPath: sep.path) &&
               FileManager.default.isReadableFile(atPath: romRoot.appendingPathComponent("SHA256SUMS").path) {
                usbSetupStatus = "ROM files found on USB. Verifying them during bundle creation…"
                setupPhase = .disk
                advanceAllUSBFiles()
            } else {
                let zip = root.appendingPathComponent("VPhone-macOS-host-ROMs.zip")
                if FileManager.default.isReadableFile(atPath: zip.path) {
                    do {
                        try VPhoneROMArchive.extract(zip, toUSB: root)
                        usbSetupStatus = "Extracted host ROM ZIP on USB."
                        setupPhase = .disk
                        advanceAllUSBFiles()
                    } catch {
                        usbSetupStatus = "USB ROM ZIP could not be extracted: \(error.localizedDescription)"
                        setupPhase = .failed
                    }
                } else if githubActionsToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    usbSetupStatus = "Step 3/4 requires a GitHub Actions: Read token. Enter it in the ROM artifact section, then tap Download everything again. Firmware already on USB will be reused."
                    setupPhase = .failed
                } else {
                    usbSetupStatus = "Step 3/4: macOS host ROMs → USB"
                    romDownload.fetch(to: root, token: githubActionsToken)
                }
            }
        case .disk:
            guard !provisioner.creatingBundle else { return }
            usbSetupStatus = "Step 4/4: creating 32 GiB Disk.img directly on USB (may be slow on exFAT)…"
            Task {
                let vm = await provisioner.createBundle(onUSB: root, pairing: selected)
                if let vm {
                    host.selectUSB(.success(root))
                    usbSetupStatus = "USB complete: both firmware archives, verified ROMs, config.plist and 32 GiB Disk.img are on the selected drive in \(vm.lastPathComponent). UNRESTORED — an empty VM disk is not a bootable iOS 27 installation."
                    setupPhase = .done
                } else {
                    usbSetupStatus = provisioner.status
                    setupPhase = .failed
                }
            }
        case .idle, .done, .failed:
            break
        }
    }

    private func firmwareStageChanged(_ active: Bool) {
        guard !active, setupPhase == .ios || setupPhase == .cloudOS else { return }
        if firmware.status.hasPrefix("Saved ") {
            setupPhase = setupPhase == .ios ? .cloudOS : .rom
            advanceAllUSBFiles()
        } else {
            usbSetupStatus = firmware.status
            setupPhase = .failed
        }
    }

    private func romStageChanged(_ active: Bool) {
        guard !active, setupPhase == .rom else { return }
        if romDownload.status.hasPrefix("Downloaded and verified") {
            setupPhase = .disk
            advanceAllUSBFiles()
        } else {
            usbSetupStatus = romDownload.status
            setupPhase = .failed
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

                    GroupBox("Everything to USB · one drive") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(workspace.root?.lastPathComponent ?? "No USB drive chosen",
                                      systemImage: "externaldrive")
                                    .font(.footnote.weight(.semibold))
                                Spacer()
                                Button("Choose USB") {
                                    choosingUSBWorkspace = true
                                }
                                .font(.caption)
                                .disabled(firmware.isDownloading || romDownload.downloading ||
                                          host.state == .running || host.state == .starting)
                            }
                            Text(workspace.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Button {
                                startAllUSBFiles()
                            } label: {
                                Label("Download everything and create 32 GB VM on USB",
                                      systemImage: "arrow.down.to.line.compact")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(firmware.isDownloading || romDownload.downloading || provisioner.creatingBundle ||
                                      host.state == .running || host.state == .starting ||
                                      host.state == .stopping)
                            Text(usbSetupStatus)
                                .font(.caption.monospaced())
                                .foregroundStyle(setupPhase == .failed ? Color.orange : Color.secondary)
                                .textSelection(.enabled)
                            if setupPhase == .ios || setupPhase == .cloudOS {
                                ProgressView(value: firmware.progress)
                            } else if setupPhase == .rom && romDownload.downloading {
                                ProgressView(value: romDownload.fraction)
                            }
                            Text("Uses the selected USB drive for original iOS IPSW + cloudOS, macOS runner ROMs, and VMs/Disk.img (32 GiB logical capacity). No full-size files are staged on iPhone. The disk is empty until the upstream OS restore stages succeed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                                    if let root = workspace.root { romDownload.fetch(to: root, token: githubActionsToken) }
                                    else { importingROMArtifactUSBFolder = true }
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

                            Text("The app now extracts and SHA-256 verifies the ROM archive directly on USB after download. No manual extraction or internal copy required.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    GroupBox("Create upstream VM · USB only") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Uses the actual upstream VPhoneBundleOps.create, the iOS/cloudOS IPSWs and the verified ROMs already on the same USB drive. The VM disk, SEP files and config.plist are created on USB.")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Create VM bundle on USB") {
                                if let root = workspace.root { Task { await prepareFromDownloadedFirmware(onUSB: root) } }
                                else { importingVMStorageFolder = true }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(firmware.isDownloading || firmware.pairings.isEmpty ||
                                      romDownload.downloading || provisioner.creatingBundle)
                            if provisioner.creatingBundle {
                                ProgressView("Creating 32 GiB USB Disk.img…")
                                    .font(.caption)
                            }
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
            .fileImporter(isPresented: $choosingUSBWorkspace, allowedContentTypes: [.folder]) { result in
                if case let .success(folder) = result {
                    do {
                        try workspace.select(folder)
                        if startAllWhenUSBChosen {
                            startAllWhenUSBChosen = false
                            beginAllUSBFiles()
                        }
                    } catch {
                        startAllWhenUSBChosen = false
                        usbSetupStatus = "Cannot use selected USB folder: \(error.localizedDescription)"
                        setupPhase = .failed
                    }
                } else {
                    startAllWhenUSBChosen = false
                }
            }
            .fileImporter(isPresented: $importingROMArtifactUSBFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let folder) = result {
                    romDownload.fetch(to: folder, token: githubActionsToken)
                }
            }
            .fileImporter(isPresented: $importingVMStorageFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(folder) = result {
                    Task { await prepareFromDownloadedFirmware(onUSB: folder) }
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
            .onChange(of: firmware.isDownloading) { _, active in
                firmwareStageChanged(active)
            }
            .onChange(of: romDownload.downloading) { _, active in
                romStageChanged(active)
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
