#!/usr/bin/env bash
# Runs inside the tiny ARM64 Linux companion VM. The companion sees Inferno's
# emulated iPhone USB device through usb-tcp-remote and performs the restore.

set -Eeuo pipefail

HOST_SHARE=/mnt/host
LOG="$HOST_SHARE/companion-restore.log"
exec > >(tee -a "$LOG") 2>&1

fail() {
  echo "COMPANION_ERROR=$*"
  printf '1\n' > "$HOST_SHARE/restore.exit"
  touch "$HOST_SHARE/restore.failed"
  exit 1
}

record_unhandled_error() {
  local rc=$?
  trap - ERR
  set +e
  echo "COMPANION_UNHANDLED_ERROR=$rc"
  if mountpoint -q "$HOST_SHARE" 2>/dev/null; then
    printf '%s\n' "$rc" > "$HOST_SHARE/restore.exit"
    touch "$HOST_SHARE/restore.failed"
  fi
  exit "$rc"
}
trap record_unhandled_error ERR

export DEBIAN_FRONTEND=noninteractive

for attempt in $(seq 1 60); do
  mountpoint -q "$HOST_SHARE" && break
  mkdir -p "$HOST_SHARE"
  mount -t 9p -o trans=virtio,version=9p2000.L,msize=104857600 hostshare "$HOST_SHARE" && break
  sleep 2
done
mountpoint -q "$HOST_SHARE" || exit 2

echo "$(date -u +%FT%TZ) companion online"
uname -a

apt-get update
apt-get install -y --no-install-recommends \
  autoconf automake build-essential ca-certificates curl git libcurl4-openssl-dev \
  libimobiledevice-dev libimobiledevice-utils libplist-dev libreadline-dev \
  libssl-dev libtool libusb-1.0-0-dev libusbmuxd-dev libusbmuxd-tools \
  libzip-dev pkg-config python3 usbmuxd

systemctl stop usbmuxd 2>/dev/null || true
pkill usbmuxd 2>/dev/null || true
rm -f /var/run/usbmuxd /var/run/usbmuxd.pid

WORK=/opt/inferno-restore
rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

# Current libirecovery separates common socket/thread helpers into the public
# libimobiledevice-glue project. Build that first because Ubuntu Noble's base
# repositories do not provide the needed development metadata here.
git clone --depth 1 https://github.com/libimobiledevice/libimobiledevice-glue.git
cd libimobiledevice-glue

# idevicerestore's 2022 source uses the former COLOR_* spellings. Current glue
# exposes equivalent FG_* constants. Add compatibility aliases to the public
# header so every old restore source file sees the same mapping.
python3 - <<'PY'
from pathlib import Path

p = Path('include/libimobiledevice-glue/termcolors.h')
s = p.read_text()
marker = '#ifdef __cplusplus\nextern "C" {\n#endif\n'
compat = r'''#ifndef COLOR_BLACK
#define COLOR_BLACK FG_BLACK
#define COLOR_DARK_GRAY FG_DARK_GRAY
#define COLOR_RED FG_RED
#define COLOR_BRIGHT_RED FG_BRIGHT_RED
#define COLOR_DARK_RED FG_DARK_RED
#define COLOR_GREEN FG_GREEN
#define COLOR_BRIGHT_GREEN FG_BRIGHT_GREEN
#define COLOR_DARK_GREEN FG_DARK_GREEN
#define COLOR_YELLOW FG_YELLOW
#define COLOR_BRIGHT_YELLOW FG_BRIGHT_YELLOW
#define COLOR_DARK_YELLOW FG_DARK_YELLOW
#define COLOR_BLUE FG_BLUE
#define COLOR_BRIGHT_BLUE FG_BRIGHT_BLUE
#define COLOR_DARK_BLUE FG_DARK_BLUE
#define COLOR_MAGENTA FG_MAGENTA
#define COLOR_BRIGHT_MAGENTA FG_BRIGHT_MAGENTA
#define COLOR_DARK_MAGENTA FG_DARK_MAGENTA
#define COLOR_CYAN FG_CYAN
#define COLOR_BRIGHT_CYAN FG_BRIGHT_CYAN
#define COLOR_DARK_CYAN FG_DARK_CYAN
#define COLOR_LIGHT_GRAY FG_LIGHT_GRAY
#define COLOR_WHITE FG_WHITE
#define COLOR_GRAY FG_GRAY
#define COLOR_DEFAULT FG_DEFAULT
#endif

'''
if '#define COLOR_WHITE FG_WHITE' not in s:
    if marker not in s:
        raise SystemExit('termcolors compatibility insertion point not found')
    s = s.replace(marker, compat + marker, 1)
p.write_text(s)
PY

./autogen.sh --prefix=/usr/local
make -j2
make install
ldconfig

export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
pkg-config --exists 'libimobiledevice-glue-1.0 >= 1.0.0' || \
  fail 'libimobiledevice-glue pkg-config metadata was not installed'

# Ubuntu Noble ARM64 does not publish libirecovery-dev. Build the public
# libirecovery generation used by the original T8030 restore flow.
cd "$WORK"
git clone --depth 200 https://github.com/libimobiledevice/libirecovery.git
cd libirecovery
LIBIRECOVERY_COMMIT="$(git rev-list -n 1 --before='2022-03-10 00:00:00 UTC' HEAD)"
[ -n "$LIBIRECOVERY_COMMIT" ] || fail 'could not resolve a compatible libirecovery commit'
git checkout "$LIBIRECOVERY_COMMIT"
./autogen.sh --prefix=/usr/local
make -j2
make install
ldconfig
command -v irecovery >/dev/null || fail 'libirecovery did not install irecovery'

cd "$WORK"
git clone --depth 200 https://github.com/libimobiledevice/idevicerestore.git
cd idevicerestore

# Use the generation of idevicerestore targeted by the original T8030 flow.
OLD_COMMIT="$(git rev-list -n 1 --before='2022-03-10 00:00:00 UTC' HEAD)"
[ -n "$OLD_COMMIT" ] || fail 'could not resolve a compatible idevicerestore commit'
git checkout "$OLD_COMMIT"

# Apply the public T8030 restore-mode changes. Fall back to a deterministic
# source edit when surrounding upstream lines differ slightly.
if ! git apply --3way "$HOST_SHARE/idevicerestore.patch"; then
  python3 - <<'PY'
from pathlib import Path

p = Path('src/idevicerestore.c')
s = p.read_text()
needle = '\tidevicerestore_progress(client, RESTORE_STEP_PREPARE, 0.2);\n'
insert = needle + '''\tif (client->mode == MODE_RESTORE) {\n\t\tif (client->flags & FLAG_ALLOW_RESTORE_MODE) {\n\t\t\ttss_enabled = 0;\n\t\t}\n\t}\n'''
if 'FLAG_ALLOW_RESTORE_MODE' not in s[s.find(needle):s.find(needle) + 400]:
    if needle not in s:
        raise SystemExit('restore-mode insertion point not found')
    s = s.replace(needle, insert, 1)
p.write_text(s)

p = Path('src/restore.c')
s = p.read_text()
needle = '\tplist_get_string_val(node, &model);\n'
insert = needle + '''\tfprintf(stderr, "%s: Found model %s\\n", __func__, model);\n\n\t/* Map the emulated DEV board to its AP restore identity. */\n\tif (strstr(model, "DEV")) {\n\t\tstrncpy(strstr(model, "DEV"), "AP\\0", 3);\n\t}\n'''
if 'Map the emulated DEV board' not in s:
    if needle not in s:
        raise SystemExit('DEV-board insertion point not found')
    s = s.replace(needle, insert, 1)
p.write_text(s)
PY
fi

# libplist 2.7 added an optional output-format argument. The old client does
# not use it, so pass NULL while preserving the original behavior.
python3 - <<'PY'
from pathlib import Path

p = Path('src/ipsw.c')
s = p.read_text()
old = 'plist_from_memory(plist_buf, plist_len, &manifest);'
new = 'plist_from_memory(plist_buf, plist_len, &manifest, NULL);'
if old in s:
    s = s.replace(old, new, 1)
elif new not in s:
    raise SystemExit('plist_from_memory compatibility call was not found')
p.write_text(s)
PY

./autogen.sh --prefix=/usr/local
make -j2
make install
ldconfig

# The longer USB descriptor timeout is useful under full TCG emulation.
cd "$WORK"
git clone --depth 200 https://github.com/libimobiledevice/usbmuxd.git
cd usbmuxd
USBMUXD_COMMIT="$(git rev-list -n 1 --before='2022-03-10 00:00:00 UTC' HEAD)"
[ -n "$USBMUXD_COMMIT" ] && git checkout "$USBMUXD_COMMIT"
git apply --3way "$HOST_SHARE/usbmuxd.patch" || true
./autogen.sh --prefix=/usr/local --without-systemd
make -j2
make install
ldconfig

/usr/local/sbin/usbmuxd -f -v > "$HOST_SHARE/usbmuxd.log" 2>&1 &
echo $! > "$HOST_SHARE/usbmuxd.pid"

# Wait for the emulated iPhone to enter restore mode.
DEVICE_READY=0
for attempt in $(seq 1 240); do
  if irecovery -q > "$HOST_SHARE/irecovery.txt" 2>&1; then
    DEVICE_READY=1
    break
  fi
  echo "$(date -u +%FT%TZ) waiting for emulated iPhone USB restore mode"
  sleep 5
done
[ "$DEVICE_READY" = 1 ] || fail 'emulated iPhone never appeared over USB'

set +e
printf 'YES\n' | /usr/local/bin/idevicerestore \
  -P -d --erase --restore-mode \
  -i 0x1122334455667788 \
  "$HOST_SHARE/iPhone11,8,iPhone12,1_14.0_18A5351d_Restore.ipsw" \
  -T "$HOST_SHARE/root_ticket.der" \
  2>&1 | tee "$HOST_SHARE/idevicerestore.log"
RESTORE_RC=${PIPESTATUS[1]}
set -e

printf '%s\n' "$RESTORE_RC" > "$HOST_SHARE/restore.exit"
if [ "$RESTORE_RC" -ne 0 ]; then
  touch "$HOST_SHARE/restore.failed"
  fail "idevicerestore exited $RESTORE_RC"
fi

touch "$HOST_SHARE/restore.done"
echo "$(date -u +%FT%TZ) restore completed; waiting for jailbroken NAND boot"

# After the host installs the bootstrap and performs the final NAND boot,
# forward the iPhone's USB SSH service to port 22222 in this companion VM.
NORMAL_READY=0
for attempt in $(seq 1 360); do
  if ideviceinfo > "$HOST_SHARE/ideviceinfo.txt" 2>&1; then
    NORMAL_READY=1
    break
  fi
  sleep 5
done
[ "$NORMAL_READY" = 1 ] || fail 'final iOS boot never appeared in normal USB mode'

pkill iproxy 2>/dev/null || true
nohup iproxy 22222 22 > "$HOST_SHARE/iproxy.log" 2>&1 &
echo $! > "$HOST_SHARE/iproxy.pid"
touch "$HOST_SHARE/iproxy.ready"

echo "$(date -u +%FT%TZ) iOS USB SSH forward ready"
while true; do sleep 300; done
