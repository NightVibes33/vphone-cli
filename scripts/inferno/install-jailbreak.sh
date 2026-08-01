#!/bin/bash
# Runs as PID 1's launch daemon inside the modified iOS update ramdisk.
# It mounts the restored NAND, overlays the public checkra1n bootstrap, and
# writes a marker that the host later verifies through root SSH.

exec >/dev/console 2>&1
set -x

echo 'INFERNO_JAILBREAK_INSTALL_START'

SYSTEM_MOUNT=/mnt1
DATA_MOUNT="$SYSTEM_MOUNT/private/var"
BOOTSTRAP=/usr/local/share/inferno-bootstrap.tar

mkdir -p "$SYSTEM_MOUNT"
SYSTEM_OK=0
for dev in /dev/disk0s1s1 /dev/disk0s1 /dev/disk1s1; do
  [ -e "$dev" ] || continue
  /sbin/mount_apfs -o rw "$dev" "$SYSTEM_MOUNT" && {
    SYSTEM_OK=1
    echo "INFERNO_SYSTEM_VOLUME=$dev"
    break
  }
done

if [ "$SYSTEM_OK" != 1 ]; then
  echo 'INFERNO_JAILBREAK_INSTALL_ERROR=system-volume-mount'
  sleep 30
  /sbin/halt
  exit 1
fi

mkdir -p "$DATA_MOUNT"
DATA_OK=0
for dev in /dev/disk0s1s2 /dev/disk0s2 /dev/disk1s2; do
  [ -e "$dev" ] || continue
  /sbin/mount_apfs -o rw "$dev" "$DATA_MOUNT" && {
    DATA_OK=1
    echo "INFERNO_DATA_VOLUME=$dev"
    break
  }
done

if [ "$DATA_OK" != 1 ]; then
  echo 'INFERNO_JAILBREAK_INSTALL_ERROR=data-volume-mount'
  /sbin/umount "$SYSTEM_MOUNT" 2>/dev/null
  sleep 30
  /sbin/halt
  exit 1
fi

[ -f "$BOOTSTRAP" ] || {
  echo 'INFERNO_JAILBREAK_INSTALL_ERROR=bootstrap-missing'
  sleep 30
  /sbin/halt
  exit 1
}

# Clear flags that can block an intentional research-device overlay.
/usr/bin/chflags -R noschg,nouchg "$SYSTEM_MOUNT" 2>/dev/null || true

/usr/bin/tar -xpf "$BOOTSTRAP" -C "$SYSTEM_MOUNT"

# Ensure the common checkra1n/OpenSSH launch daemons are enabled when present.
for plist in \
  "$SYSTEM_MOUNT/Library/LaunchDaemons/com.openssh.sshd.plist" \
  "$SYSTEM_MOUNT/Library/LaunchDaemons/com.saurik.Cydia.Startup.plist" \
  "$SYSTEM_MOUNT/Library/LaunchDaemons/com.checkra1n.loader.plist"; do
  [ -f "$plist" ] && /usr/bin/chmod 0644 "$plist"
done

/usr/bin/touch "$SYSTEM_MOUNT/.inferno-jailbroken"
/usr/bin/touch "$DATA_MOUNT/.inferno-jailbroken"
/usr/bin/sync

echo 'INFERNO_JAILBREAK_INSTALL_DONE'
sleep 8
/sbin/halt
