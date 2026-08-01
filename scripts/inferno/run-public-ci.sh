#!/usr/bin/env bash
# Prepare a CI-safe copy of the public Inferno pipeline and execute it.
# Keeping the edits in one wrapper makes failures easy to compare against the
# original boot script while the first runner attempts are being stabilized.

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

# The workflow activates a private venv. --user is invalid inside a venv.
s = s.replace(
    "python3 -m pip install --user --disable-pip-version-check pyasn1",
    "python3 -m pip install --disable-pip-version-check pyasn1",
)

# -nographic rewires serial/monitor devices and conflicts with the explicit
# serial log and TCP monitor used by the companion VM.
s = s.replace("  -display none -nographic \\\n", "  -display none \\\n")

# Preserve Apple's restore launch daemons. The installer daemon is additive;
# deleting the restore services can prevent launchd and USB restore startup.
s = s.replace(
    'sudo rm -f "$RAMDISK_MOUNT/System/Library/LaunchDaemons/"*.plist\n',
    '',
)

# The original generated file contained literal backslash-newline strings.
# Send normal HMP commands and bound netcat so a closed monitor cannot hang CI.
s = s.replace(
    "printf 'quit\\\n' | nc 127.0.0.1 1235",
    "printf 'quit\\n' | nc -w 2 127.0.0.1 1235",
)
s = s.replace(
    "printf 'change vnc password %s\\\n' \"$VNC_PASSWORD\" | nc 127.0.0.1 1235",
    "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc -w 2 127.0.0.1 1235",
)

# Current macOS nc accepts -w and the monitor is plain TCP.
s = s.replace(
    "printf 'quit\\n' | nc 127.0.0.1 1235",
    "printf 'quit\\n' | nc -w 2 127.0.0.1 1235",
)
s = s.replace(
    "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc 127.0.0.1 1235",
    "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc -w 2 127.0.0.1 1235",
)

out.write_text(s)
PY

chmod +x "$PATCHED"
bash -n "$PATCHED"
exec "$PATCHED"
