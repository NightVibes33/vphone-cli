#!/usr/bin/env bash
# Apply runner-specific hardening to the public Inferno pipeline in a temporary
# copy, then execute it. This keeps the boot recipe readable while making the
# GitHub-hosted macOS execution deterministic.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$SCRIPT_DIR/public-github-boot.sh"
RUNTIME="${RUNNER_TEMP:-/tmp}/inferno-public-github-boot.runtime.sh"

[ -f "$SOURCE" ] || {
  echo "missing source pipeline: $SOURCE" >&2
  exit 1
}

cp "$SOURCE" "$RUNTIME"

python3 - "$RUNTIME" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

replacements = [
    (
        "python3 -m pip install --user --disable-pip-version-check pyasn1",
        "PYTHON_VENV=\"$WORK/python-venv\"\n"
        "python3 -m venv \"$PYTHON_VENV\"\n"
        "\"$PYTHON_VENV/bin/python\" -m pip install --disable-pip-version-check pyasn1\n"
        "PYTHON_BIN=\"$PYTHON_VENV/bin/python\"",
    ),
    (
        'python3 "$TOOLS_SRC/bootstrap_scripts/create_apticket.py"',
        '"$PYTHON_BIN" "$TOOLS_SRC/bootstrap_scripts/create_apticket.py"',
    ),
    (
        'python3 "$TOOLS_SRC/bootstrap_scripts/asn1rdskdecode.py"',
        '"$PYTHON_BIN" "$TOOLS_SRC/bootstrap_scripts/asn1rdskdecode.py"',
    ),
    (
        '  -display none -nographic \\\n',
        '  -display none \\\n',
    ),
    (
        "printf 'quit\\n' | nc 127.0.0.1 1235",
        "printf 'quit\\n' | nc -w 2 127.0.0.1 1235",
    ),
    (
        'VNC_PASSWORD="$(openssl rand -base64 18 | tr -dc \'A-Za-z0-9\' | head -c 12)"',
        'VNC_PASSWORD="$(openssl rand -hex 6)"',
    ),
    (
        "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc 127.0.0.1 1235",
        "printf 'change vnc password %s\\n' \"$VNC_PASSWORD\" | nc -w 2 127.0.0.1 1235",
    ),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, got {count}: {old[:90]!r}")
    text = text.replace(old, new, 1)

path.write_text(text)
PY

chmod +x "$RUNTIME"
exec bash "$RUNTIME"
