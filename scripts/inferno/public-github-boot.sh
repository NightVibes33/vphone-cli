#!/usr/bin/env bash
# Fully public, zero-secret iPhone 11 / iOS 14 beta 5 emulation pipeline.
# Downloads firmware from Apple's CDN, builds Inferno, restores iOS through a
# tiny Linux USB companion VM, installs a checkra1n bootstrap, and succeeds only
# after SpringBoard and root SSH are both verified.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORK="${INFERNO_WORK_DIR:-${RUNNER_TEMP:-/tmp}/inferno-public-iphone}"
LOG_DIR="$WORK/logs"
SHARE="$WORK/share"
BIN_DIR="$WORK/bin"
FW_DIR="$WORK/firmware"
SOURCE_DIR="$WORK/source"
RAMDISK_MOUNT="$WORK/ramdisk-mount"
RESULT_ENV="$WORK/result.env"

IPSW_NAME='iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw'
IPSW_URL='https://updates.cdn-apple.com/2020SummerSeed/fullrestores/001-35886/5FE9BE2E-17F8-41C8-96BB-B76E2B225888/iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw'
UBUNTU_IMAGE_URL='https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img'
RESTORE_TIMEOUT_SECONDS="${INFERNO_RESTORE_TIMEOUT_SECONDS:-14400}"
INSTALL_TIMEOUT_SECONDS="${INFERNO_INSTALL_TIMEOUT_SECONDS:-1800}"
BOOT_TIMEOUT_SECONDS="${INFERNO_BOOT_TIMEOUT_SECONDS:-3600}"

mkdir -p "$WORK" "$LOG_DIR" "$SHARE" "$BIN_DIR" "$FW_DIR" "$SOURCE_DIR"
rm -f /tmp/usbqemu "$RESULT_ENV"

fail() {
  echo "error: $*" >&2
  tail -n 200 "$LOG_DIR/ios-final.log" 2>/dev/null || true
  tail -n 200 "$SHARE/companion-restore.log" 2>/dev/null || true
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

for tool in git curl jq python3 unzip tar hdiutil mkisofs nc openssl ssh sshpass; do
  require "$tool"
done

CPU_COUNT="$(sysctl -n hw.logicalcpu 2>/dev/null || echo 3)"
[ "$CPU_COUNT" -gt 3 ] && CPU_COUNT=3

INFERNO_SRC="$SOURCE_DIR/Inferno"
TOOLS_SRC="$SOURCE_DIR/qemu-t8030-tools"
IPSW="$WORK/$IPSW_NAME"
QEMU="$BIN_DIR/qemu-system-aarch64"
QEMU_IMG="$BIN_DIR/qemu-img"
UEFI="$BIN_DIR/edk2-aarch64-code.fd"

if [ ! -x "$QEMU" ]; then
  echo 'Cloning and building Inferno for Apple ARM plus the Linux companion VM.'
  git clone --depth 1 --recurse-submodules --shallow-submodules \
    https://github.com/ChefKissInc/Inferno.git "$INFERNO_SRC"

  mkdir -p "$INFERNO_SRC/build"
  pushd "$INFERNO_SRC/build" >/dev/null
  HOMEBREW_PREFIX="$(brew --prefix)"
  export PATH="$HOMEBREW_PREFIX/opt/libtool/libexec/gnubin:$HOME/.local/bin:$PATH"
  export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/opt/openssl@3/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

  LIBTOOL=glibtool ../configure \
    --target-list=aarch64-softmmu \
    --disable-guest-agent \
    --enable-slirp \
    --enable-lzfse \
    --enable-nettle \
    --enable-gnutls \
    --enable-libssh \
    --enable-virtfs \
    --enable-zstd \
    --enable-curses \
    --enable-cocoa \
    --disable-sdl \
    --disable-gtk \
    --disable-werror \
    --extra-cflags="-I$HOMEBREW_PREFIX/include" \
    --extra-ldflags="-L$HOMEBREW_PREFIX/lib"
  make -j"$CPU_COUNT"
  popd >/dev/null

  cp "$INFERNO_SRC/build/qemu-system-aarch64" "$QEMU"
  cp "$INFERNO_SRC/build/qemu-img" "$QEMU_IMG"
  chmod +x "$QEMU" "$QEMU_IMG"

  UEFI_SOURCE="$(find "$INFERNO_SRC" -type f \( -name 'edk2-aarch64-code.fd' -o -name 'edk2-aarch64-code.fd.bz2' \) | head -n1)"
  [ -n "$UEFI_SOURCE" ] || fail 'Inferno build did not provide ARM UEFI firmware'
  case "$UEFI_SOURCE" in
    *.bz2) bzip2 -dc "$UEFI_SOURCE" > "$UEFI" ;;
    *) cp "$UEFI_SOURCE" "$UEFI" ;;
  esac

  "$QEMU" -device help 2>&1 | grep -q 'usb-tcp-remote' || \
    fail 'Inferno build is missing usb-tcp-remote'

  # The built executables and UEFI are all that later stages need.
  rm -rf "$INFERNO_SRC"
fi

if [ ! -d "$TOOLS_SRC" ]; then
  git clone --depth 1 https://github.com/TrungNguyen1909/qemu-t8030-tools.git "$TOOLS_SRC"
fi
python3 -m pip install --user --disable-pip-version-check pyasn1

if [ ! -f "$IPSW" ]; then
  echo 'Downloading iOS 14 beta 5 directly from Apple.'
  curl --fail --location --retry 5 --retry-delay 5 \
    --output "$IPSW.part" "$IPSW_URL"
  mv "$IPSW.part" "$IPSW"
fi

# Extract only the boot components. idevicerestore consumes the untouched IPSW.
rm -rf "$FW_DIR"
mkdir -p "$FW_DIR"
unzip -q "$IPSW" \
  BuildManifest.plist \
  kernelcache.research.iphone12b \
  038-44087-125.dmg \
  038-44135-124.dmg \
  Firmware/038-44087-125.dmg.trustcache \
  Firmware/038-44135-124.dmg.trustcache \
  Firmware/all_flash/DeviceTree.n104ap.im4p \
  -d "$FW_DIR"

for required in \
  BuildManifest.plist kernelcache.research.iphone12b \
  038-44087-125.dmg 038-44135-124.dmg \
  Firmware/038-44087-125.dmg.trustcache \
  Firmware/038-44135-124.dmg.trustcache \
  Firmware/all_flash/DeviceTree.n104ap.im4p; do
  [ -f "$FW_DIR/$required" ] || fail "IPSW component missing: $required"
done

python3 "$TOOLS_SRC/bootstrap_scripts/create_apticket.py" \
  n104ap "$FW_DIR/BuildManifest.plist" \
  "$TOOLS_SRC/bootstrap_scripts/ticket.shsh2" \
  "$SHARE/root_ticket.der"
[ -s "$SHARE/root_ticket.der" ] || fail 'AP ticket generation failed'

# Hard-link the original Apple IPSW into the 9p share without consuming a
# second copy of the runner disk.
rm -f "$SHARE/$IPSW_NAME"
ln "$IPSW" "$SHARE/$IPSW_NAME"
cp "$TOOLS_SRC/libimobiledevice_patches/idevicerestore.patch" "$SHARE/"
cp "$TOOLS_SRC/libimobiledevice_patches/usbmuxd.patch" "$SHARE/"
cp "$PROJECT_ROOT/scripts/inferno/companion-restore.sh" "$SHARE/"
chmod +x "$SHARE/companion-restore.sh"

# Build a modified update ramdisk that installs the public checkra1n bootstrap
# onto the already-restored NAND.
STRAP_URL="$(curl --fail --location https://assets.checkra.in/loader/config.json | jq -r '.core_bootstrap_tar')"
[ -n "$STRAP_URL" ] && [ "$STRAP_URL" != null ] || fail 'checkra1n bootstrap URL unavailable'
curl --fail --location --retry 5 -o "$WORK/strap.tar.lzma" "$STRAP_URL"
rm -rf "$WORK/strap"
mkdir -p "$WORK/strap"
tar xf "$WORK/strap.tar.lzma" -C "$WORK/strap"
tar -cpf "$WORK/inferno-bootstrap.tar" -C "$WORK/strap" .

MODIFIED_RAMDISK="$WORK/038-44087-125.dmg.out"
python3 "$TOOLS_SRC/bootstrap_scripts/asn1rdskdecode.py" \
  "$FW_DIR/038-44087-125.dmg" "$MODIFIED_RAMDISK"

hdiutil resize -size 768m -imagekey diskimage-class=CRawDiskImage "$MODIFIED_RAMDISK"
rm -rf "$RAMDISK_MOUNT"
mkdir -p "$RAMDISK_MOUNT"
hdiutil attach -nobrowse -owners on \
  -imagekey diskimage-class=CRawDiskImage \
  -mountpoint "$RAMDISK_MOUNT" "$MODIFIED_RAMDISK"

RAMDISK_ATTACHED=1
cleanup_ramdisk() {
  if [ "${RAMDISK_ATTACHED:-0}" = 1 ]; then
    hdiutil detach "$RAMDISK_MOUNT" -force >/dev/null 2>&1 || true
  fi
}
trap cleanup_ramdisk EXIT

sudo rsync -a "$WORK/strap/" "$RAMDISK_MOUNT/"
sudo mkdir -p "$RAMDISK_MOUNT/usr/local/bin" "$RAMDISK_MOUNT/usr/local/share"
sudo cp "$PROJECT_ROOT/scripts/inferno/install-jailbreak.sh" \
  "$RAMDISK_MOUNT/usr/local/bin/inferno-install-jailbreak.sh"
sudo cp "$WORK/inferno-bootstrap.tar" \
  "$RAMDISK_MOUNT/usr/local/share/inferno-bootstrap.tar"
sudo chmod 0755 "$RAMDISK_MOUNT/usr/local/bin/inferno-install-jailbreak.sh"

sudo mkdir -p "$RAMDISK_MOUNT/System/Library/LaunchDaemons"
sudo rm -f "$RAMDISK_MOUNT/System/Library/LaunchDaemons/"*.plist
sudo cp "$PROJECT_ROOT/scripts/inferno/com.github.inferno.install.plist" \
  "$RAMDISK_MOUNT/System/Library/LaunchDaemons/com.github.inferno.install.plist"
sudo chmod 0644 "$RAMDISK_MOUNT/System/Library/LaunchDaemons/com.github.inferno.install.plist"
sync
hdiutil detach "$RAMDISK_MOUNT"
RAMDISK_ATTACHED=0
trap - EXIT

# Persistent emulated NAND namespaces. qemu-img creates sparse raw files.
create_raw() {
  local path="$1" size="$2"
  [ -f "$path" ] || "$QEMU_IMG" create -f raw "$path" "$size"
}
create_raw "$SHARE/nvme.1" 32G
create_raw "$SHARE/nvme.2" 8M
create_raw "$SHARE/nvme.3" 128K
create_raw "$SHARE/nvme.4" 8K
create_raw "$SHARE/nvram" 8K
create_raw "$SHARE/nvme.6" 4K
create_raw "$SHARE/nvme.7" 1M

# Create the ARM64 Linux USB companion VM. It builds patched idevicerestore and
# operates the iPhone through Inferno's /tmp/usbqemu transport.
UBUNTU_IMAGE="$WORK/noble-server-cloudimg-arm64.img"
if [ ! -f "$UBUNTU_IMAGE" ]; then
  curl --fail --location --retry 5 -o "$UBUNTU_IMAGE.part" "$UBUNTU_IMAGE_URL"
  mv "$UBUNTU_IMAGE.part" "$UBUNTU_IMAGE"
fi
"$QEMU_IMG" resize "$UBUNTU_IMAGE" 8G

SEED_DIR="$WORK/seed"
SEED_ISO="$WORK/seed.iso"
rm -rf "$SEED_DIR" "$SEED_ISO"
mkdir -p "$SEED_DIR"
cat > "$SEED_DIR/meta-data" <<'EOF'
instance-id: inferno-usb-companion
local-hostname: inferno-usb-companion
EOF
cat > "$SEED_DIR/user-data" <<'EOF'
#cloud-config
ssh_pwauth: false
disable_root: true
runcmd:
  - [ bash, -lc, 'mkdir -p /mnt/host; for i in $(seq 1 60); do mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 hostshare /mnt/host && break; sleep 2; done; chmod +x /mnt/host/companion-restore.sh; /mnt/host/companion-restore.sh' ]
EOF
mkisofs -quiet -output "$SEED_ISO" -volid cidata -joliet -rock \
  "$SEED_DIR/user-data" "$SEED_DIR/meta-data"

COMPANION_LOG="$LOG_DIR/companion-serial.log"
nohup "$QEMU" \
  -machine virt \
  -accel tcg,thread=multi \
  -cpu max -smp 2 -m 1024 \
  -bios "$UEFI" \
  -drive if=none,file="$UBUNTU_IMAGE",format=qcow2,id=companion-os \
  -device virtio-blk-pci,drive=companion-os \
  -drive file="$SEED_ISO",format=raw,media=cdrom,readonly=on \
  -netdev user,id=companion-net,hostfwd=tcp:127.0.0.1:22222-:22222 \
  -device virtio-net-pci,netdev=companion-net \
  -fsdev local,id=hostshare,path="$SHARE",security_model=none \
  -device virtio-9p-pci,fsdev=hostshare,mount_tag=hostshare \
  -device qemu-xhci,id=xhci \
  -device usb-tcp-remote,bus=xhci.0 \
  -display none -nographic \
  -serial "file:$COMPANION_LOG" \
  -monitor tcp:127.0.0.1:1236,server=on,wait=off \
  > "$LOG_DIR/companion-qemu.log" 2>&1 &
COMPANION_PID=$!
echo "$COMPANION_PID" > "$WORK/companion.pid"

for attempt in $(seq 1 180); do
  kill -0 "$COMPANION_PID" 2>/dev/null || fail 'Linux USB companion exited early'
  [ -S /tmp/usbqemu ] && break
  sleep 2
done
[ -S /tmp/usbqemu ] || fail 'Linux companion did not create /tmp/usbqemu'

IOS_COMMON_DRIVES=(
  -drive "file=$SHARE/nvme.1,format=raw,if=none,id=drive.1"
  -device 'nvme-ns,drive=drive.1,bus=nvme-bus.0,nsid=1,nstype=1,logical_block_size=4096,physical_block_size=4096'
  -drive "file=$SHARE/nvme.2,format=raw,if=none,id=drive.2"
  -device 'nvme-ns,drive=drive.2,bus=nvme-bus.0,nsid=2,nstype=2,logical_block_size=4096,physical_block_size=4096'
  -drive "file=$SHARE/nvme.3,format=raw,if=none,id=drive.3"
  -device 'nvme-ns,drive=drive.3,bus=nvme-bus.0,nsid=3,nstype=3,logical_block_size=4096,physical_block_size=4096'
  -drive "file=$SHARE/nvme.4,format=raw,if=none,id=drive.4"
  -device 'nvme-ns,drive=drive.4,bus=nvme-bus.0,nsid=4,nstype=4,logical_block_size=4096,physical_block_size=4096'
  -drive "file=$SHARE/nvram,format=raw,if=none,id=nvram"
  -device 'apple-nvram,drive=nvram,bus=nvme-bus.0,nsid=5,nstype=5,id=nvram,logical_block_size=4096,physical_block_size=4096'
  -drive "file=$SHARE/nvme.6,format=raw,if=none,id=drive.6"
  -device 'nvme-ns,drive=drive.6,bus=nvme-bus.0,nsid=6,nstype=6,logical_block_size=4096,physical_block_size=4096'
  -drive "file=$SHARE/nvme.7,format=raw,if=none,id=drive.7"
  -device 'nvme-ns,drive=drive.7,bus=nvme-bus.0,nsid=7,nstype=8,logical_block_size=4096,physical_block_size=4096'
)

stop_ios() {
  local pid="${1:-}"
  printf 'quit\n' | nc 127.0.0.1 1235 >/dev/null 2>&1 || true
  sleep 3
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
}

launch_auto_ios() {
  local log="$1"
  rm -f "$log"
  nohup "$QEMU" \
    -M "t8030,trustcache-filename=$FW_DIR/Firmware/038-44135-124.dmg.trustcache,ticket-filename=$SHARE/root_ticket.der" \
    -kernel "$FW_DIR/kernelcache.research.iphone12b" \
    -dtb "$FW_DIR/Firmware/all_flash/DeviceTree.n104ap.im4p" \
    -append 'debug=0x14e kextlog=0xffff serial=3 -v wdt=-1' \
    -initrd "$FW_DIR/038-44135-124.dmg" \
    -accel tcg,thread=multi -cpu max -smp 3 -m 3072 \
    "${IOS_COMMON_DRIVES[@]}" \
    -display none -vnc 127.0.0.1:1,password=on \
    -serial "file:$log" \
    -monitor tcp:127.0.0.1:1235,server=on,wait=off \
    > "$LOG_DIR/ios-qemu.log" 2>&1 &
  IOS_PID=$!
  echo "$IOS_PID" > "$WORK/ios.pid"
}

launch_installer_ios() {
  local log="$1"
  rm -f "$log"
  nohup "$QEMU" \
    -M "t8030,trustcache-filename=$FW_DIR/Firmware/038-44087-125.dmg.trustcache,ticket-filename=$SHARE/root_ticket.der,boot-mode=manual" \
    -kernel "$FW_DIR/kernelcache.research.iphone12b" \
    -dtb "$FW_DIR/Firmware/all_flash/DeviceTree.n104ap.im4p" \
    -append 'debug=0x14e kextlog=0xffff serial=3 -v rd=md0 wdt=-1' \
    -initrd "$MODIFIED_RAMDISK" \
    -accel tcg,thread=multi -cpu max -smp 2 -m 3072 \
    "${IOS_COMMON_DRIVES[@]}" \
    -display none -vnc 127.0.0.1:1 \
    -serial "file:$log" \
    -monitor tcp:127.0.0.1:1235,server=on,wait=off \
    > "$LOG_DIR/ios-installer-qemu.log" 2>&1 &
  IOS_PID=$!
  echo "$IOS_PID" > "$WORK/ios.pid"
}

# First auto boot enters restore mode because the NAND is empty.
RESTORE_LOG="$LOG_DIR/ios-restore.log"
launch_auto_ios "$RESTORE_LOG"
RESTORE_DEADLINE=$(( $(date +%s) + RESTORE_TIMEOUT_SECONDS ))
while (( $(date +%s) < RESTORE_DEADLINE )); do
  kill -0 "$IOS_PID" 2>/dev/null || fail 'iOS restore VM exited early'
  kill -0 "$COMPANION_PID" 2>/dev/null || fail 'Linux companion exited during restore'
  [ -f "$SHARE/restore.failed" ] && fail 'companion reported restore failure'
  [ -f "$SHARE/restore.done" ] && break
  echo "$(date -u +%FT%TZ) waiting for public iOS restore"
  sleep 20
done
[ -f "$SHARE/restore.done" ] || fail 'iOS restore timed out'
[ "$(cat "$SHARE/restore.exit")" = 0 ] || fail 'idevicerestore did not succeed'
sleep 20
stop_ios "$IOS_PID"

# Boot the modified update ramdisk once and install the jailbreak bootstrap.
INSTALL_LOG="$LOG_DIR/ios-jailbreak-install.log"
launch_installer_ios "$INSTALL_LOG"
INSTALL_DEADLINE=$(( $(date +%s) + INSTALL_TIMEOUT_SECONDS ))
while (( $(date +%s) < INSTALL_DEADLINE )); do
  kill -0 "$IOS_PID" 2>/dev/null || {
    grep -q 'INFERNO_JAILBREAK_INSTALL_DONE' "$INSTALL_LOG" && break
    fail 'jailbreak installer VM exited before completion'
  }
  grep -q 'INFERNO_JAILBREAK_INSTALL_ERROR' "$INSTALL_LOG" && fail 'ramdisk jailbreak installer failed'
  grep -q 'INFERNO_JAILBREAK_INSTALL_DONE' "$INSTALL_LOG" && break
  sleep 5
done
grep -q 'INFERNO_JAILBREAK_INSTALL_DONE' "$INSTALL_LOG" || fail 'jailbreak install timed out'
stop_ios "$IOS_PID"

# Final NAND boot. Success requires kernel bypass evidence, SpringBoard, and a
# root SSH session through the USB companion.
FINAL_LOG="$LOG_DIR/ios-final.log"
launch_auto_ios "$FINAL_LOG"
VNC_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 12)"

for attempt in $(seq 1 60); do
  nc -z 127.0.0.1 5901 >/dev/null 2>&1 && break
  kill -0 "$IOS_PID" 2>/dev/null || fail 'final iOS VM exited before VNC started'
  sleep 2
done
nc -z 127.0.0.1 5901 || fail 'final VNC framebuffer did not start'
printf 'change vnc password %s\n' "$VNC_PASSWORD" | nc 127.0.0.1 1235 >/dev/null 2>&1 || \
  fail 'could not set the one-time VNC password'

BOOT_DEADLINE=$(( $(date +%s) + BOOT_TIMEOUT_SECONDS ))
while (( $(date +%s) < BOOT_DEADLINE )); do
  kill -0 "$IOS_PID" 2>/dev/null || fail 'final iOS VM exited during boot'
  AMFI_OK=0
  UI_OK=0
  SSH_OK=0
  grep -q 'AMFI is running in RESEARCH mode' "$FINAL_LOG" && AMFI_OK=1
  grep -Eq 'SpringBoard|backboardd' "$FINAL_LOG" && UI_OK=1
  nc -z 127.0.0.1 22222 >/dev/null 2>&1 && SSH_OK=1
  if [ "$AMFI_OK" = 1 ] && [ "$UI_OK" = 1 ] && [ "$SSH_OK" = 1 ]; then
    break
  fi
  echo "$(date -u +%FT%TZ) waiting: amfi=$AMFI_OK ui=$UI_OK ssh=$SSH_OK"
  sleep 10
done

grep -q 'AMFI is running in RESEARCH mode' "$FINAL_LOG" || fail 'AMFI research-mode patch not observed'
grep -Eq 'SpringBoard|backboardd' "$FINAL_LOG" || fail 'SpringBoard/backboardd was not observed'
nc -z 127.0.0.1 22222 || fail 'USB SSH forward did not start'

set +e
sshpass -p alpine ssh \
  -p 22222 \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=20 \
  root@127.0.0.1 \
  'test "$(id -u)" = 0 && test -e /.inferno-jailbroken && uname -a' \
  > "$LOG_DIR/root-ssh-proof.txt" 2>&1
SSH_PROOF_RC=$?
set -e
[ "$SSH_PROOF_RC" = 0 ] || fail 'root SSH or jailbreak marker verification failed'

{
  echo 'BOOTED=1'
  echo 'SPRINGBOARD=1'
  echo 'AMFI_RESEARCH_MODE=1'
  echo 'ROOT_SSH=1'
  echo 'JAILBREAK_MARKER=1'
  echo "VNC_PASSWORD=$VNC_PASSWORD"
  echo "IOS_PID=$IOS_PID"
  echo "COMPANION_PID=$COMPANION_PID"
  echo "WORK=$WORK"
} | tee "$RESULT_ENV"

echo 'INFERNO_PUBLIC_IPHONE_READY=1'
