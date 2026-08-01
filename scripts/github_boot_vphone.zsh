#!/bin/zsh
# Boot a persistent vphone VM on a real Apple-silicon Mac and return only
# after the guest's VNC framebuffer is reachable.

set -euo pipefail

VM_NAME="${1:-github-phone}"
VARIANT="${2:-jb}"
LOG_DIR="${3:-${RUNNER_TEMP:-/tmp}/vphone-remote-lab}"
BOOT_TIMEOUT_SECONDS="${VPHONE_BOOT_TIMEOUT_SECONDS:-1800}"
POLL_SECONDS="${VPHONE_BOOT_POLL_SECONDS:-5}"

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
VPHONE_BIN="${VPHONE_CLI_BIN:-${PROJECT_ROOT}/.build/vphone-cli.app/Contents/MacOS/vphone-cli}"

mkdir -p "$LOG_DIR"
LAUNCH_LOG="$LOG_DIR/vphone-launch.log"
PID_FILE="$LOG_DIR/vphone-launch.pid"
GUEST_IP_FILE="$LOG_DIR/guest-ip.txt"
VM_INFO_FILE="$LOG_DIR/vm-info.json"
CREATE_LOG="$LOG_DIR/vm-create.log"

fail() {
  echo "error: $*" >&2
  [[ -f "$LAUNCH_LOG" ]] && tail -n 240 "$LAUNCH_LOG" >&2 || true
  exit 1
}

[[ "$(uname -m)" == "arm64" ]] || fail "vphone requires Apple silicon (arm64)."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]] || fail "vphone requires macOS 15 or newer."
[[ -x "$VPHONE_BIN" ]] || fail "missing built vphone-cli at $VPHONE_BIN"

MODEL_NAME="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ {print $2; exit}')"
HV_VMM_PRESENT="$(sysctl -n kern.hv_vmm_present 2>/dev/null || true)"
if [[ "$HV_VMM_PRESENT" == "1" || "$MODEL_NAME" == "Apple Virtual Machine 1" ]]; then
  fail "nested macOS VM detected. PV=3 cannot boot inside a GitHub-hosted or other virtual Mac."
fi

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
CURRENT_USER="$(id -un)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" != "$CURRENT_USER" ]]; then
  fail "the runner must be started with ./run.sh by the currently logged-in Mac desktop user; a background service cannot reliably host the visible vphone window."
fi

VPHONE_CLI_BIN="$VPHONE_BIN" "$PROJECT_ROOT/scripts/boot_host_preflight.sh" --assert-bootable \
  2>&1 | tee "$LOG_DIR/preflight.log"

if "$VPHONE_BIN" vm info "$VM_NAME" --json >"$VM_INFO_FILE" 2>/dev/null; then
  echo "Reusing persistent VM: $VM_NAME"
else
  echo "Creating and restoring persistent VM: $VM_NAME (variant: $VARIANT)"
  sudo -n true || fail "passwordless sudo is required for the dedicated runner account."

  while sleep 45; do
    sudo -n true >/dev/null 2>&1 || exit
  done &
  SUDO_KEEPALIVE_PID=$!

  set +e
  "$VPHONE_BIN" vm create "$VM_NAME" -V "$VARIANT" --keep-artifacts -vv \
    2>&1 | tee "$CREATE_LOG"
  CREATE_RC=${pipestatus[1]}
  set -e

  kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
  wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  (( CREATE_RC == 0 )) || fail "vm create failed with exit code $CREATE_RC"
  "$VPHONE_BIN" vm info "$VM_NAME" --json >"$VM_INFO_FILE"
fi

"$VPHONE_BIN" vm stop "$VM_NAME" --timeout 10 >/dev/null 2>&1 || true
rm -f "$LAUNCH_LOG" "$PID_FILE" "$GUEST_IP_FILE"

# Launch exactly as documented upstream. The firmware variant is selected at
# create/patch time; vm launch does not need a -V argument.
nohup "$VPHONE_BIN" vm launch "$VM_NAME" >"$LAUNCH_LOG" 2>&1 &
LAUNCH_PID=$!
echo "$LAUNCH_PID" >"$PID_FILE"

DEADLINE=$(( EPOCHSECONDS + BOOT_TIMEOUT_SECONDS ))
GUEST_IP=""

while (( EPOCHSECONDS < DEADLINE )); do
  kill -0 "$LAUNCH_PID" >/dev/null 2>&1 || fail "vphone launch exited before the guest became reachable."

  CANDIDATES="$({
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$LAUNCH_LOG" 2>/dev/null || true
    arp -an 2>/dev/null | awk '{gsub(/[()]/, "", $2); if ($2 ~ /^[0-9]+\./) print $2}' || true
  } | sort -u)"

  for IP in ${(f)CANDIDATES}; do
    case "$IP" in
      0.*|127.*|169.254.*|224.*|255.*) continue ;;
    esac
    if nc -z -G 2 "$IP" 5901 >/dev/null 2>&1; then
      GUEST_IP="$IP"
      break 2
    fi
  done

  echo "$(date -u +%FT%TZ) waiting for virtual iPhone VNC on port 5901..."
  sleep "$POLL_SECONDS"
done

[[ -n "$GUEST_IP" ]] || fail "virtual iPhone did not expose VNC within ${BOOT_TIMEOUT_SECONDS}s."
echo "$GUEST_IP" >"$GUEST_IP_FILE"

echo "BOOTED=1"
echo "VM_NAME=$VM_NAME"
echo "GUEST_IP=$GUEST_IP"
echo "VNC=vnc://$GUEST_IP:5901"
