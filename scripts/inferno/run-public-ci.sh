#!/usr/bin/env bash
# Prepare a CI-safe copy of the public Inferno pipeline and execute it.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="$ROOT/scripts/inferno/public-github-boot.sh"
PATCHED="${RUNNER_TEMP:-/tmp}/inferno-public-github-boot.ci.sh"
PYTHON_BIN="${INFERNO_PYTHON:-python3}"

"$PYTHON_BIN" - "$SOURCE" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text()

def replace_once(old: str, new: str, label: str) -> None:
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    s = s.replace(old, new, 1)

# The executable copy lives under RUNNER_TEMP, so resolve repository assets from
# the explicit checkout path rather than from $0.
replace_once(
    '''SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"''',
    'PROJECT_ROOT="${INFERNO_PROJECT_ROOT:?INFERNO_PROJECT_ROOT is required}"',
    "repository root",
)

replace_once(
    "python3 -m pip install --user --disable-pip-version-check pyasn1",
    "python3 -m pip install --disable-pip-version-check pyasn1",
    "pip mode",
)

# Inferno's ROM submodules are firmware build inputs for many unrelated QEMU
# targets. The Apple ARM emulator build only needs the mlib helper.
replace_once(
    "  git clone --depth 1 --recurse-submodules --shallow-submodules \\\n"
    "    https://github.com/ChefKissInc/Inferno.git \"$INFERNO_SRC\"",
    "  git clone --depth 1 https://github.com/ChefKissInc/Inferno.git \"$INFERNO_SRC\"\n"
    "  git -C \"$INFERNO_SRC\" submodule update --init --depth 1 util/mlib",
    "minimal Inferno clone",
)

# Inferno intentionally leaves the macOS executable unsigned and gives it an
# -unsigned suffix. Accept either upstream output name.
replace_once(
    '  cp "$INFERNO_SRC/build/qemu-system-aarch64" "$QEMU"',
    '''  QEMU_SOURCE="$INFERNO_SRC/build/qemu-system-aarch64"
  if [ ! -x "$QEMU_SOURCE" ]; then
    QEMU_SOURCE="$INFERNO_SRC/build/qemu-system-aarch64-unsigned"
  fi
  [ -x "$QEMU_SOURCE" ] || fail 'Inferno did not produce an aarch64 system executable'
  cp "$QEMU_SOURCE" "$QEMU"''',
    "Inferno executable name",
)

# The Linux companion needs ARM UEFI, not Inferno's huge EDK2 source tree.
old_uefi = '''  UEFI_SOURCE="$(find "$INFERNO_SRC" -type f \\( -name 'edk2-aarch64-code.fd' -o -name 'edk2-aarch64-code.fd.bz2' \\) | head -n1)"
  [ -n "$UEFI_SOURCE" ] || fail 'Inferno build did not provide ARM UEFI firmware'
  case "$UEFI_SOURCE" in
    *.bz2) bzip2 -dc "$UEFI_SOURCE" > "$UEFI" ;;
    *) cp "$UEFI_SOURCE" "$UEFI" ;;
  esac'''
new_uefi = '''  QEMU_SHARE="$(brew --prefix qemu)/share/qemu"
  UEFI_SOURCE="$(find "$QEMU_SHARE" -maxdepth 2 -type f \\( -name 'edk2-aarch64-code.fd' -o -name 'edk2-aarch64-code.fd.bz2' \\) | head -n1)"
  [ -n "$UEFI_SOURCE" ] || fail 'Homebrew QEMU did not provide ARM UEFI firmware'
  case "$UEFI_SOURCE" in
    *.bz2) bzip2 -dc "$UEFI_SOURCE" > "$UEFI" ;;
    *) cp "$UEFI_SOURCE" "$UEFI" ;;
  esac'''
replace_once(old_uefi, new_uefi, "packaged ARM UEFI")

# The companion boots from its virtio disk and never performs PXE. Inferno is
# copied out of its build tree, so disabling option ROM lookup avoids requiring
# efi-virtio.rom beside the executable.
replace_once(
    '  -device virtio-blk-pci,drive=companion-os \\\n',
    '  -device virtio-blk-pci,drive=companion-os,romfile= \\\n',
    "companion block option ROM",
)
replace_once(
    '  -device virtio-net-pci,netdev=companion-net \\\n',
    '  -device virtio-net-pci,netdev=companion-net,romfile= \\\n',
    "companion network option ROM",
)

# usb-tcp-remote reports this as its default path. Use the actual upstream
# default consistently instead of waiting on the obsolete qemu-t8030 path.
socket_refs = s.count('/tmp/usbqemu')
if socket_refs < 2:
    raise SystemExit(f"USB socket path: expected at least two matches, found {socket_refs}")
s = s.replace('/tmp/usbqemu', '/tmp/InfernoUSBRemote')

replace_once(
    "  -display none -nographic \\\n",
    "  -display none \\\n",
    "companion display flags",
)

# Preserve Apple's restore launch daemons. The installer daemon is additive.
replace_once(
    'sudo rm -f "$RAMDISK_MOUNT/System/Library/LaunchDaemons/"*.plist\n',
    '',
    "restore launch daemons",
)

# Bound monitor connections so a stopped QEMU process cannot hang the job.
s = s.replace(
    "printf 'quit\\\\n' | nc 127.0.0.1 1235",
    "printf 'quit\\n' | nc -w 2 127.0.0.1 1235",
)
s = s.replace(
    "printf 'quit\\n' | nc 127.0.0.1 1235",
    "printf 'quit\\n' | nc -w 2 127.0.0.1 1235",
)
s = s.replace(
    "printf 'change vnc password %s\\\\n' \"$VNC_PASSWORD\" | nc 127.0.0.1 1235",
    "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc -w 2 127.0.0.1 1235",
)
s = s.replace(
    "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc 127.0.0.1 1235",
    "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc -w 2 127.0.0.1 1235",
)

s = s.replace(
    'VNC_PASSWORD="$(openssl rand -base64 18 | tr -dc \'A-Za-z0-9\' | head -c 12)"',
    'VNC_PASSWORD="$(openssl rand -hex 6)"',
)

out.write_text(s)
PY

chmod +x "$PATCHED"
bash -n "$PATCHED"
export INFERNO_PROJECT_ROOT="$ROOT"
exec "$PATCHED"
