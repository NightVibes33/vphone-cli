#!/bin/bash
# Boot a vphone iOS guest on a physical Apple-silicon GitHub runner and
# expose the guest to the user's real iPhone through both native VNC and noVNC.
#
# This script intentionally refuses nested/hosted macOS VMs. vphone-cli uses
# Apple's private PV=3 Virtualization.framework path, which requires a real,
# non-nested Apple-silicon host prepared according to the upstream README.

set -euo pipefail

VM_NAME="github-phone"
VARIANT="jb"
KEEP_ALIVE_MINUTES="300"
VPHONE_BIN=""
TAILSCALE_IP=""
ENABLE_NOVNC="1"
BOOT_TIMEOUT_SECONDS="1800"

usage() {
  cat <<'EOF'
Usage: scripts/github_boot_iphone.sh [options]

Options:
  --vm-name NAME              Persistent VM name (default: github-phone)
  --variant NAME              less|regular|dev|jb|exp (default: jb)
  --keep-alive-minutes N      Keep VNC/noVNC online (default: 300)
  --vphone-bin PATH           Existing vphone-cli binary
  --tailscale-ip IP           Tailscale IPv4 address; auto-detected otherwise
  --boot-timeout-seconds N    Wait for the iPhone VNC service (default: 1800)
  --no-novnc                  Publish native VNC only
  -h, --help                  Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vm-name)
      VM_NAME="$2"; shift 2 ;;
    --variant)
      VARIANT="$2"; shift 2 ;;
    --keep-alive-minutes)
      KEEP_ALIVE_MINUTES="$2"; shift 2 ;;
    --vphone-bin)
      VPHONE_BIN="$2"; shift 2 ;;
    --tailscale-ip)
      TAILSCALE_IP="$2"; shift 2 ;;
    --boot-timeout-seconds)
      BOOT_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --no-novnc)
      ENABLE_NOVNC="0"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

case "$VARIANT" in
  less|regular|dev|jb|exp) ;;
  *) echo "Unsupported variant: $VARIANT" >&2; exit 2 ;;
esac

case "$KEEP_ALIVE_MINUTES" in
  ''|*[!0-9]*) echo "keep-alive minutes must be an integer" >&2; exit 2 ;;
esac
case "$BOOT_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "boot timeout must be an integer" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_TEMP="${RUNNER_TEMP:-${TMPDIR:-/tmp}/vphone-github-runner}"
LOG_DIR="$RUN_TEMP/vphone-iphone"
mkdir -p "$LOG_DIR"

HOST_FACTS="$LOG_DIR/host-facts.txt"
CREATE_LOG="$LOG_DIR/vm-create.log"
LAUNCH_LOG="$LOG_DIR/vphone-launch.log"
VM_INFO="$LOG_DIR/vm-info.json"
REMOTE_ADDRESSES="$LOG_DIR/remote-addresses.txt"
BOOT_RESULT="$LOG_DIR/boot-result.json"

VPHONE_PID=""
USBMUX_VNC_PID=""
USBMUX_SSH_PID=""
VNC_PROXY_PID=""
SSH_PROXY_PID=""
NOVNC_PID=""
BACKEND_HOST=""
BACKEND_VNC_PORT=""
BACKEND_SSH_PORT=""
GUEST_IP=""

cleanup_on_failure() {
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "Boot failed with exit $rc" >&2
    tail -n 200 "$LAUNCH_LOG" 2>/dev/null || true
    for pid in "$NOVNC_PID" "$VNC_PROXY_PID" "$SSH_PROXY_PID" "$USBMUX_VNC_PID" "$USBMUX_SSH_PID"; do
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    done
    if [ -n "$VPHONE_PID" ]; then
      kill "$VPHONE_PID" 2>/dev/null || true
    fi
  fi
}
trap cleanup_on_failure EXIT

section() {
  echo
  echo "========== $1 =========="
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command is missing: $1" >&2
    exit 10
  }
}

section "Validate physical Apple-silicon host"
require_command sw_vers
require_command sysctl
require_command csrutil
require_command codesign
require_command nc
require_command sudo
require_command brew
require_command git

ARCH="$(uname -m)"
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
MODEL_NAME="$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Model Name/ {print $2; exit}')"
HV_VMM_PRESENT="$(sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)"
HV_SUPPORT="$(sysctl -n kern.hv_support 2>/dev/null || echo 0)"
SIP_STATUS="$(csrutil status 2>&1 || true)"
RESEARCH_STATUS="$(csrutil allow-research-guests status </dev/null 2>&1 || true)"

{
  echo "date=$(date -u +%FT%TZ)"
  echo "arch=$ARCH"
  echo "macOS=$MACOS_VERSION"
  echo "model=$MODEL_NAME"
  echo "kern.hv_vmm_present=$HV_VMM_PRESENT"
  echo "kern.hv_support=$HV_SUPPORT"
  echo "SIP=$SIP_STATUS"
  echo "allow-research-guests=$RESEARCH_STATUS"
} | tee "$HOST_FACTS"

[ "$ARCH" = "arm64" ] || {
  echo "vphone requires Apple silicon (arm64)." >&2
  exit 11
}
[ "$MACOS_MAJOR" -ge 15 ] || {
  echo "vphone requires macOS 15 or newer." >&2
  exit 12
}
if [ "$HV_VMM_PRESENT" = "1" ] || [ "$MODEL_NAME" = "Apple Virtual Machine 1" ]; then
  echo "This Mac is itself virtualized. Nested vphone boot is unavailable." >&2
  exit 13
fi
[ "$HV_SUPPORT" = "1" ] || {
  echo "Apple Virtualization.framework hardware support is unavailable." >&2
  exit 14
}
sudo -n true || {
  echo "The dedicated runner account needs passwordless sudo." >&2
  exit 15
}

section "Install runtime networking tools"
brew list socat >/dev/null 2>&1 || brew install socat
require_command socat

if [ -z "$TAILSCALE_IP" ]; then
  require_command tailscale
  TAILSCALE_IP="$(tailscale ip -4 2>/dev/null | head -n 1)"
fi
[ -n "$TAILSCALE_IP" ] || {
  echo "No Tailscale IPv4 address is available." >&2
  exit 16
}

section "Build vphone-cli"
cd "$PROJECT_ROOT"
if [ -z "$VPHONE_BIN" ]; then
  ./scripts/setup_tools.sh 2>&1 | tee "$LOG_DIR/setup-tools.log"
  ./scripts/build.sh 2>&1 | tee "$LOG_DIR/build.log"
  VPHONE_BIN="$PROJECT_ROOT/.build/vphone-cli.app/Contents/MacOS/vphone-cli"
fi
[ -x "$VPHONE_BIN" ] || {
  echo "vphone-cli binary not found at $VPHONE_BIN" >&2
  exit 17
}

section "Verify private-entitlement execution policy"
VPHONE_CLI_BIN="$VPHONE_BIN" ./scripts/boot_host_preflight.sh --assert-bootable \
  2>&1 | tee "$LOG_DIR/preflight.log"

section "Create or reuse iPhone VM"
if "$VPHONE_BIN" vm info "$VM_NAME" --json >"$VM_INFO" 2>/dev/null; then
  echo "Reusing persistent VM: $VM_NAME"
else
  echo "Creating iPhone VM: $VM_NAME (variant: $VARIANT)"
  "$VPHONE_BIN" vm create "$VM_NAME" -V "$VARIANT" --keep-artifacts -vv \
    2>&1 | tee "$CREATE_LOG"
  "$VPHONE_BIN" vm info "$VM_NAME" --json >"$VM_INFO"
fi
cat "$VM_INFO"

section "Launch virtual iPhone"
"$VPHONE_BIN" vm stop "$VM_NAME" --timeout 10 >/dev/null 2>&1 || true

# GitHub's runner process cleanup must not kill the child while this job is
# intentionally keeping the remote session alive.
RUNNER_TRACKING_ID="" nohup "$VPHONE_BIN" vm launch "$VM_NAME" -V "$VARIANT" -vv \
  >"$LAUNCH_LOG" 2>&1 &
VPHONE_PID=$!
echo "$VPHONE_PID" >"$LOG_DIR/vphone-launch.pid"

sleep 15
kill -0 "$VPHONE_PID" 2>/dev/null || {
  echo "vphone exited during initial launch." >&2
  tail -n 200 "$LAUNCH_LOG" >&2 || true
  exit 18
}

find_vphone_python() {
  for candidate in \
    "$HOME/.vphone/venv/bin/python3" \
    "$HOME/.vphone/venv/bin/python" \
    "$PROJECT_ROOT/.venv/bin/python3" \
    "$PROJECT_ROOT/.venv/bin/python"; do
    if [ -x "$candidate" ] && "$candidate" -c 'import pymobiledevice3' >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

collect_candidate_ips() {
  {
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$LAUNCH_LOG" 2>/dev/null || true
    grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' "$VM_INFO" 2>/dev/null || true
    arp -an 2>/dev/null | awk '{gsub(/[()]/, "", $2); if ($2 ~ /^[0-9]+\./) print $2}' || true
  } | sort -u
}

is_usable_candidate() {
  ip="$1"
  case "$ip" in
    0.*|127.*|169.254.*|224.*|255.*) return 1 ;;
  esac
  [ "$ip" != "$TAILSCALE_IP" ] || return 1
  return 0
}

section "Wait for the iPhone framebuffer"
# Start usbmux fallbacks as soon as the virtual device becomes visible to
# pymobiledevice3. Direct guest-IP VNC remains the preferred backend.
if VPHONE_PYTHON="$(find_vphone_python)"; then
  RUNNER_TRACKING_ID="" nohup "$VPHONE_PYTHON" -m pymobiledevice3 usbmux forward 15901 5901 \
    >"$LOG_DIR/usbmux-vnc.log" 2>&1 &
  USBMUX_VNC_PID=$!
  echo "$USBMUX_VNC_PID" >"$LOG_DIR/usbmux-vnc.pid"

  RUNNER_TRACKING_ID="" nohup "$VPHONE_PYTHON" -m pymobiledevice3 usbmux forward 12222 22222 \
    >"$LOG_DIR/usbmux-ssh.log" 2>&1 &
  USBMUX_SSH_PID=$!
  echo "$USBMUX_SSH_PID" >"$LOG_DIR/usbmux-ssh.pid"
else
  echo "pymobiledevice3 Python environment not found; direct guest discovery only."
fi

START_TIME="$(date +%s)"
while :; do
  kill -0 "$VPHONE_PID" 2>/dev/null || {
    echo "vphone exited before its VNC service became reachable." >&2
    exit 19
  }

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    is_usable_candidate "$candidate" || continue
    if nc -z -G 2 "$candidate" 5901 >/dev/null 2>&1; then
      GUEST_IP="$candidate"
      BACKEND_HOST="$candidate"
      BACKEND_VNC_PORT="5901"
      if nc -z -G 2 "$candidate" 22222 >/dev/null 2>&1; then
        BACKEND_SSH_PORT="22222"
      fi
      break 2
    fi
  done <<EOF
$(collect_candidate_ips)
EOF

  if nc -z -G 2 127.0.0.1 15901 >/dev/null 2>&1; then
    BACKEND_HOST="127.0.0.1"
    BACKEND_VNC_PORT="15901"
    if nc -z -G 2 127.0.0.1 12222 >/dev/null 2>&1; then
      BACKEND_SSH_PORT="12222"
    fi
    break
  fi

  NOW="$(date +%s)"
  ELAPSED=$((NOW - START_TIME))
  if [ "$ELAPSED" -ge "$BOOT_TIMEOUT_SECONDS" ]; then
    echo "Timed out waiting for the virtual iPhone VNC service after ${ELAPSED}s." >&2
    exit 20
  fi

  echo "$(date -u +%FT%TZ) waiting for iPhone VNC (${ELAPSED}s elapsed)"
  tail -n 8 "$LAUNCH_LOG" 2>/dev/null || true
  sleep 10
done

section "Publish native iPhone VNC"
# Reserve the public host ports before spawning proxies. A stale previous
# session should fail clearly instead of silently forwarding the wrong VM.
if nc -z -G 1 127.0.0.1 5901 >/dev/null 2>&1; then
  echo "Host port 5901 is already in use. Stop the previous remote session." >&2
  exit 21
fi

RUNNER_TRACKING_ID="" nohup socat \
  TCP-LISTEN:5901,bind=0.0.0.0,reuseaddr,fork \
  TCP:"$BACKEND_HOST":"$BACKEND_VNC_PORT" \
  >"$LOG_DIR/socat-vnc.log" 2>&1 &
VNC_PROXY_PID=$!
echo "$VNC_PROXY_PID" >"$LOG_DIR/socat-vnc.pid"

if [ -n "$BACKEND_SSH_PORT" ] && ! nc -z -G 1 127.0.0.1 22222 >/dev/null 2>&1; then
  RUNNER_TRACKING_ID="" nohup socat \
    TCP-LISTEN:22222,bind=0.0.0.0,reuseaddr,fork \
    TCP:"$BACKEND_HOST":"$BACKEND_SSH_PORT" \
    >"$LOG_DIR/socat-ssh.log" 2>&1 &
  SSH_PROXY_PID=$!
  echo "$SSH_PROXY_PID" >"$LOG_DIR/socat-ssh.pid"
fi

for _ in $(seq 1 30); do
  nc -z -G 1 127.0.0.1 5901 >/dev/null 2>&1 && break
  sleep 1
done
nc -z -G 2 127.0.0.1 5901 >/dev/null 2>&1 || {
  echo "The native VNC proxy did not start." >&2
  exit 22
}

NOVNC_URL=""
if [ "$ENABLE_NOVNC" = "1" ]; then
  section "Publish iPhone Safari noVNC"
  NOVNC_ROOT="$RUN_TEMP/noVNC"
  NOVNC_VENV="$RUN_TEMP/novnc-venv"
  if [ ! -f "$NOVNC_ROOT/vnc.html" ]; then
    rm -rf "$NOVNC_ROOT"
    git clone --depth 1 https://github.com/novnc/noVNC.git "$NOVNC_ROOT"
  fi
  if [ ! -x "$NOVNC_VENV/bin/websockify" ]; then
    rm -rf "$NOVNC_VENV"
    python3 -m venv "$NOVNC_VENV"
    "$NOVNC_VENV/bin/python" -m pip install --upgrade pip websockify
  fi

  RUNNER_TRACKING_ID="" nohup "$NOVNC_VENV/bin/websockify" \
    --web "$NOVNC_ROOT" 6080 127.0.0.1:5901 \
    >"$LOG_DIR/novnc.log" 2>&1 &
  NOVNC_PID=$!
  echo "$NOVNC_PID" >"$LOG_DIR/novnc.pid"

  for _ in $(seq 1 30); do
    nc -z -G 1 127.0.0.1 6080 >/dev/null 2>&1 && break
    sleep 1
  done
  nc -z -G 2 127.0.0.1 6080 >/dev/null 2>&1 || {
    echo "noVNC did not start." >&2
    exit 23
  }
  NOVNC_URL="http://$TAILSCALE_IP:6080/vnc.html?autoconnect=true&resize=scale&view_only=false"
fi

NATIVE_VNC_URL="vnc://$TAILSCALE_IP:5901"
SSH_COMMAND=""
[ -n "$SSH_PROXY_PID" ] && SSH_COMMAND="ssh -p 22222 mobile@$TAILSCALE_IP"

cat >"$BOOT_RESULT" <<EOF
{
  "booted": true,
  "deviceClass": "iPhone",
  "vmName": "$VM_NAME",
  "variant": "$VARIANT",
  "guestIP": "$GUEST_IP",
  "vncBackend": "$BACKEND_HOST:$BACKEND_VNC_PORT",
  "nativeVNC": "$NATIVE_VNC_URL",
  "noVNC": "$NOVNC_URL",
  "ssh": "$SSH_COMMAND",
  "tailscaleIP": "$TAILSCALE_IP",
  "verifiedAt": "$(date -u +%FT%TZ)"
}
EOF

{
  echo "Virtual iPhone boot verified: yes"
  echo "Native VNC: $NATIVE_VNC_URL"
  [ -n "$NOVNC_URL" ] && echo "Safari/noVNC: $NOVNC_URL"
  [ -n "$SSH_COMMAND" ] && echo "SSH: $SSH_COMMAND"
  [ -n "$GUEST_IP" ] && echo "Guest IP: $GUEST_IP"
} | tee "$REMOTE_ADDRESSES"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "VPHONE_BOOTED=true"
    echo "VPHONE_NATIVE_VNC=$NATIVE_VNC_URL"
    echo "VPHONE_NOVNC=$NOVNC_URL"
    echo "VPHONE_SSH=$SSH_COMMAND"
  } >>"$GITHUB_ENV"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## ✅ Virtual iPhone booted"
    echo
    echo "- Device class: **iPhone**"
    echo "- VM: \`$VM_NAME\`"
    echo "- Variant: \`$VARIANT\`"
    echo "- Boot verification: guest VNC service accepted a TCP connection"
    echo "- Native iPhone VNC app: \`$NATIVE_VNC_URL\`"
    if [ -n "$NOVNC_URL" ]; then
      echo "- iPhone Safari/noVNC: [$NOVNC_URL]($NOVNC_URL)"
    fi
    if [ -n "$SSH_COMMAND" ]; then
      echo "- SSH: \`$SSH_COMMAND\`"
      echo "- Default jailbreak password: \`alpine\`"
    fi
    echo
    echo "Your real iPhone must have Tailscale enabled on the same tailnet."
  } >>"$GITHUB_STEP_SUMMARY"
fi

section "Keep the verified iPhone session online"
END_TIME=$(( $(date +%s) + KEEP_ALIVE_MINUTES * 60 ))
while [ "$(date +%s)" -lt "$END_TIME" ]; do
  kill -0 "$VPHONE_PID" 2>/dev/null || {
    echo "vphone exited after boot." >&2
    exit 24
  }
  kill -0 "$VNC_PROXY_PID" 2>/dev/null || {
    echo "VNC proxy exited after boot." >&2
    exit 25
  }
  if [ "$ENABLE_NOVNC" = "1" ]; then
    kill -0 "$NOVNC_PID" 2>/dev/null || {
      echo "noVNC exited after boot." >&2
      exit 26
    }
  fi
  nc -z -G 2 127.0.0.1 5901 >/dev/null 2>&1 || {
    echo "The virtual iPhone framebuffer stopped responding." >&2
    exit 27
  }
  echo "$(date -u +%FT%TZ) virtual iPhone online at $NATIVE_VNC_URL"
  sleep 60
done

section "Stop remote session"
for pid in "$NOVNC_PID" "$VNC_PROXY_PID" "$SSH_PROXY_PID" "$USBMUX_VNC_PID" "$USBMUX_SSH_PID"; do
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
done
"$VPHONE_BIN" vm stop "$VM_NAME" --timeout 30 || true
VPHONE_PID=""
trap - EXIT
