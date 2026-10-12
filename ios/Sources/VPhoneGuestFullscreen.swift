import SwiftUI
import UIKit

/// Genuine guest display. No mocked lock screen, SpringBoard, app icons, or
/// boot animation. The only image source is the VZ guest graphics framebuffer.
struct VPhoneGuestFullscreen: View {
    @EnvironmentObject private var host: VPhoneHost
    @State private var toolsVisible = true
    @State private var confirmShutdown = false
    @State private var shareLogs = false

    private var mayReturnToSetup: Bool {
        host.state == .failed || host.state == .stopped || host.state == .idle
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                MetalGuestView(
                    frameStore: host.frames,
                    onTouch: { phase, x, y in
                        host.sendGuestTouch(phase: phase, x: x, y: y)
                    }
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Color.black)

                // Only a real framebuffer can replace the boot-status overlay.
                // Successful VZ VM start is NOT reported as successful iOS boot.
                if !host.guestHasRealFrame {
                    VStack(spacing: 14) {
                        if host.state == .starting {
                            ProgressView().tint(.white)
                                .scaleEffect(1.15)
                        }
                        Text(host.state == .failed ? "Guest boot failed" : "iOS 27 guest")
                            .font(.title3.weight(.semibold))
                        Text(host.guestBootStatus)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                        Text(host.guestBootError ?? host.detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                        if host.state == .stopUnconfirmed {
                            Label("Keep USB storage connected until shutdown completes",
                                  systemImage: "externaldrive.badge.exclamationmark")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 340)
                    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
                    .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    HStack {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                toolsVisible.toggle()
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(.black.opacity(0.55), in: Capsule())
                        }
                        .accessibilityLabel("Virtual iPhone controls")
                        Spacer()
                        if host.state == .starting || host.state == .stopping {
                            ProgressView().tint(.white)
                                .padding(12)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 54)

                    Spacer()

                    if toolsVisible {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(host.guestBootStatus)
                                .font(.footnote.monospaced())
                                .lineLimit(3)
                                .textSelection(.enabled)

                            HStack(spacing: 9) {
                                if host.state == .running {
                                    Button("Home") {
                                        host.sendHardwareKey(.home)
                                    }
                                    .buttonStyle(.bordered)
                                    Button("Power") {
                                        host.sendHardwareKey(.power)
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Button {
                                    shareLogs = true
                                } label: {
                                    Label("Logs", systemImage: "doc.text")
                                }
                                .buttonStyle(.bordered)

                                Spacer(minLength: 0)

                                if mayReturnToSetup {
                                    Button {
                                        host.closeGuestFullscreen()
                                    } label: {
                                        Label("Back", systemImage: "arrow.backward")
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else if host.state == .running || host.state == .stopUnconfirmed {
                                    Button(role: .destructive) {
                                        confirmShutdown = true
                                    } label: {
                                        Label("Stop", systemImage: "power")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .font(.caption)
                        }
                        .padding(16)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 42)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden()
        .interactiveDismissDisabled()
        .confirmationDialog(
            "Shut down the virtual iPhone?",
            isPresented: $confirmShutdown,
            titleVisibility: .visible
        ) {
            Button("Stop guest", role: .destructive) {
                host.stop()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The external USB drive must stay connected until VPhone confirms the VM has stopped.")
        }
        .sheet(isPresented: $shareLogs) {
            VPhoneGuestLogShareSheet(items: [host.exportDiagnostics()])
        }
    }
}

private struct VPhoneGuestLogShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
