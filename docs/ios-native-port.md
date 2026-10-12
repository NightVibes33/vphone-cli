# Native iOS host for vphone-cli

The port lives in this existing NightVibes33/vphone-cli fork, under ios/.
The Xcode target now compiles original sources/VPhoneCore manifest, bundle,
restore info, firmware catalog and boot pattern sources, without duplicating
their data formats. Existing macOS VM creation, firmware patching and guest
tools are unchanged on their original target.
It is a real iOS SwiftUI app and native Apple VM creation attempt, not a
WKWebView, off-device streaming, fake SpringBoard, or QEMU.

## Real pieces implemented

* CPU: requests real guest CPU virtualization from Apple's PV=3 VM backend,
  capped at four cores for host responsiveness.
* GPU: configures a VM graphics device, uses the same private VZGraphicsDisplay
  screenshot selector as upstream, and presents returned real CVPixelBuffers
  with Metal. No fake SpringBoard frames are displayed. The rendering view
  targets 60 FPS, but screenshot capture is throttled to 15 FPS.
* JIT: checks local MAP_JIT memory-mapping availability. This check does not grant
  executable JIT permission or hypervisor access. No software CPU translator exists.
* LocalDevVPN: checks a user-adjustable TCP endpoint for reachability. It does not
  configure the VPN or implement an authenticated RemoteServiceDiscovery protocol.
* Pairing file: user imports plist from Files, verified as a property list,
  stored in ThisDeviceOnly Keychain, never embedded in IPA, source, or logs.
  The full pairing protocol client is not implemented.
* USB: imports an existing VM folder, keeps its security-scoped bookmark open,
  and passes Disk.img in-place to VZ storage. Storage visibility is checked
  while running; the VM is asked to stop if USB disappears. This cannot undo
  corruption caused by physically unplugging a live guest disk. Some external
  File Providers may cache files internally, deny random writes, or refuse
  long-lived security-scoped access.
* Firmware staging: the original VPhoneFirmwareCatalog's iOS 27 beta IPSW and
  cloudOS Apple CDN URLs can be downloaded in streaming chunks directly to
  user-selected USB storage. HTTP Range resumes a .partial file if supported.
  It requires VPhone to remain foregrounded; downloading firmware is NOT a
  replacement for Apple's DFU restore or the upstream binary patch pipeline.
* Guest controls: consumer HID Home/Power/Volume controls use actual upstream
  vphoned messages over virtio socket port 1337 after a protocol-v1 handshake.
* Diagnostics: exports the real guest PL011 serial tail (up to ~600 KB), host
  events, VM capability findings and frame counters; screenshot sharing exports
  real received guest frames only.

The required iOS 27 guest ROM, NVRAM, SEP, disk and config must already exist
inside the selected folder. The IPA does NOT include or download a guest OS.

## Hard blocker for a real iOS 27 guest

Upstream vphone-cli uses macOS private PV=3 research virtualization entitlements.
Normal iOS / SideStore signing does not grant them. No combination of GPU, CPU,
Metal, JIT, LocalDevVPN, pairing file, or public entitlements creates privileged
VMM access. There is no verified unrestricted virtualization API on a stock
iPhone 16 with iOS 27. The backend attempts native API calls and reports the
specific failure rather than fabricating a guest boot.

The native bridge now calls upstream's real _takeScreenshotWithCompletionHandler
on VZGraphicsDisplay and attempts a VSOCK v1 handshake with vphoned at port 1337.
The Metal view forwards real touch phases (0/1/3) to vphoned's touch RPC once
connected. Guest resources are never faked when no VM exists. A CI-green IPA
is only compilation evidence, NOT proof that SpringBoard boots.

Do not add private entitlements to the IPA without an Apple-authorized
provisioning profile. Additional memory and networking entitlements are
provisioning-dependent and are not universal performance switches.

## Build unsigned IPA with GitHub Actions

Workflow: VPhone iOS native IPA

Manual local build:

    brew install xcodegen
    xcodegen generate --spec ios/project.yml --project ios
    xcodebuild -project ios/VPhoneiOS.xcodeproj -scheme VPhoneiOS \
      -configuration Release -sdk iphoneos \
      -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build

GitHub Actions packages VPhoneiOS-unsigned.ipa for sideload signing.

On device use Files to select the prepared VM folder from a mounted USB drive.
Keep the drive connected for the entire VM lifetime, and stop the VM before
unplugging it. Pairing data remains encrypted at rest in this phone's Keychain.


## Guest display, compatibility and remaining gaps

The app now has the original manifest/restore-info reader, real attempted
PV=3 VM creation, ROM/NVRAM/SEP/disk preflight, guest display capture, host
Metal rendering, PL011 serial capture, vphoned VSOCK v1 handshake, touch and
consumer-page HID injection, USB direct disk selection and unplug detection,
and foreground-only IPSW/cloudOS streaming downloads to USB.
Without a running authorized VM or display object, no frames are fabricated.

The iOS code still cannot run upstream's Python/shell firmware preparation,
privileged APFS CFW installer, host filesystem mounts, or macOS DFU restore.
It consumes a PREPARED VPhone bundle with previously restored iOS 27 firmware.
Importing a pairing plist and pinging LocalDevVPN do NOT authorize the PV=3
VMM or automatically install vphoned. Guest IPA installation now uses the real vphoned `file_mkdir` / `file_put`
streaming / `ipa_install` / cleanup protocol, without loading the entire IPA
in memory. Guest app list and launch requests are wired into the native iOS
interface. The guest agent must already be running inside a booted VM. Full VSOCK
functionality requires a VM that actually boots.
No stock iPhone 16 running iOS 27 has been verified booting an iOS 27 guest
with this IPA. A green unsigned IPA is only proof of compilation and packaging.


## iPhone limitations and interpretation

* The absence of a hypervisor service is a HARD blocker; a JIT entitlement,
  larger memory entitlement, VPN tunnel, pairing record, or Metal device
  cannot replace VZVirtualMachine authorization.
* SideStore may sign the IPA as a normal app but cannot grant Apple-private
  PV=3 security-research entitlements. Boot must be tested on physical device
  and only marked functional after an actual serial boot and SpringBoard frame.
* The firmware stager only downloads Apple archives; importing them does not
  constitute successful guest restore. Use a prepared upstream VM bundle.
* The host VM RAM is conservatively capped at half physical device memory,
  up to 4 GiB. The available memory might not be enough for an iOS 27 guest.


## New guest application management

When a genuine iOS guest is running and vphoned has replied to the version-1
VSOCK handshake, the host can enumerate installed guest user applications,
stream an IPA into a temporary guest path in 64 KiB chunks, request genuine
IPA registration from the daemon, and launch guest bundle identifiers.
Those controls stay inert before the guest connects. The host does not
sideload IPA content into its own iOS app container as a substitute for the
virtual device.
