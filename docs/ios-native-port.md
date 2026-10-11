# Native iOS host for vphone-cli

The port lives in this existing NightVibes33/vphone-cli fork, under ios/.
It is a real iOS SwiftUI app and native Apple VM creation attempt, not a
WKWebView, off-device streaming, fake SpringBoard, or QEMU.

## Real pieces implemented

* CPU: requests real guest CPU virtualization from Apple's PV=3 VM backend,
  capped at four cores for host responsiveness.
* GPU: configures a VM graphics device and renders received real CVPixelBuffers
  using a 60 FPS MetalKit / CoreImage Metal renderer. Guest framebuffer extraction
  still requires privileged VM graphics access and is not hooked up.
* JIT: checks local MAP_JIT memory-mapping availability. This check does not grant
  executable JIT permission or hypervisor access. No software CPU translator exists.
* LocalDevVPN: checks a user-adjustable TCP endpoint for reachability. It does not
  configure the VPN or implement an authenticated RemoteServiceDiscovery protocol.
* Pairing file: user imports plist from Files, verified as a property list,
  stored in ThisDeviceOnly Keychain, never embedded in IPA, source, or logs.
  The full pairing protocol client is not implemented.
* USB: imports the folder containing an existing prepared VM bundle, keeps its
  security-scoped bookmark open during execution, and passes Disk.img directly
  to the virtual disk API. No disk copy onto internal storage. A filesystem
  provider may still deny write access or lose its grant on reconnection.

The required iOS 27 guest ROM, NVRAM, SEP, disk and config must already exist
inside the selected folder. The IPA does NOT include or download a guest OS.

## Hard blocker for a real iOS 27 guest

Upstream vphone-cli uses macOS private PV=3 research virtualization entitlements.
Normal iOS / SideStore signing does not grant them. No combination of GPU, CPU,
Metal, JIT, LocalDevVPN, pairing file, or public entitlements creates privileged
VMM access. There is no verified unrestricted virtualization API on a stock
iPhone 16 with iOS 27. The backend attempts native API calls and reports the
specific failure rather than fabricating a guest boot.

The Metal frame source, actual touch injection and full RSD guest control cannot
work until a permitted VM backend exposes guest display/input. A CI-green IPA
is only compilation evidence, NOT proof that SpringBoard boots.

Do not add private entitlements to the IPA without an Apple-authorized
provisioning profile. Additional memory and networking entitlements are
provisioning-dependent and are not universal performance switches.

## Build unsigned IPA with GitHub Actions

Workflow: VPhone iOS native IPA

Manual local build:

    brew install xcodegen
    xcodegen generate --spec ios/project.yml --project ios/VPhoneiOS.xcodeproj
    xcodebuild -project ios/VPhoneiOS.xcodeproj -scheme VPhoneiOS \
      -configuration Release -sdk iphoneos \
      -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

GitHub Actions packages VPhoneiOS-unsigned.ipa for sideload signing.

On device use Files to select the prepared VM folder from a mounted USB drive.
Keep the drive connected for the entire VM lifetime, and stop the VM before
unplugging it. Pairing data remains encrypted at rest in this phone's Keychain.
