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

replace_once(
    "python3 -m pip install --user --disable-pip-version-check pyasn1",
    "python3 -m pip install --disable-pip-version-check pyasn1",
    "pip mode",
)

# Inferno's ROM submodules are firmware build inputs for many unrelated QEMU
# targets. The Apple ARM emulator build only needs the mlib helper. Avoid a
# recursive checkout of EDK2, OpenSSL, U-Boot, SeaBIOS, and their descendants.
replace_once(
    "  git clone --depth 1 --recurse-submodules --shallow-submodules \\\n"
    "    https://github.com/ChefKissInc/Inferno.git \"$INFERNO_SRC\"",
    "  git clone --depth 1 https://github.com/ChefKissInc/Inferno.git \"$INFERNO_SRC\"\n"
    "  git -C \"$INFERNO_SRC\" submodule update --init --depth 1 util/mlib",
    "minimal Inferno clone",
)

# The Linux companion needs ARM UEFI, not Inferno's huge EDK2 source tree.
# Homebrew QEMU ships a ready-to-use firmware image.
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

# Avoid pipefail/SIGPIPE from filtering random bytes through head.
s = s.replace(
    'VNC_PASSWORD="$(openssl rand -base64 18 | tr -dc \'A-Za-z0-9\' | head -c 12)"',
    'VNC_PASSWORD="$(openssl rand -hex 6)"',
)

out.write_text(s)
PY

chmod +x "$PATCHED"
bash -n "$PATCHED"
exec "$PATCHED"
