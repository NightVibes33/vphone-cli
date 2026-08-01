#!/usr/bin/env python3
"""Patch current Inferno for an unencrypted simulated-SEP research VM.

Inferno currently enables ENABLE_DATA_ENCRYPTION in its normal Apple ARM build.
The T8030 machine deliberately aborts when that feature is combined with the
simulated SEP. Our public CI guest has no real SEP ROM/firmware and uses an
ephemeral, unencrypted research NAND, so select the already-implemented
simulated-SEP branch instead.
"""

from __future__ import annotations

import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} INFERNO_SOURCE_ROOT", file=sys.stderr)
        return 2

    source_root = Path(sys.argv[1]).resolve()
    t8030 = source_root / "hw/arm/apple-silicon/t8030.c"
    if not t8030.is_file():
        print(f"error: missing Inferno T8030 source: {t8030}", file=sys.stderr)
        return 1

    text = t8030.read_text(encoding="utf-8")
    old = "#ifdef ENABLE_DATA_ENCRYPTION\n        error_setg(&error_fatal, \"Simulated SEP cannot be used with data \""
    new = "#if 0 /* public unencrypted research VM: use Inferno's simulated SEP */\n        error_setg(&error_fatal, \"Simulated SEP cannot be used with data \""

    count = text.count(old)
    if count != 1:
        print(
            "error: expected exactly one simulated-SEP encryption gate, "
            f"found {count}",
            file=sys.stderr,
        )
        return 1

    t8030.write_text(text.replace(old, new, 1), encoding="utf-8")

    patched = t8030.read_text(encoding="utf-8")
    if "public unencrypted research VM" not in patched:
        print("error: simulated-SEP patch did not persist", file=sys.stderr)
        return 1

    print(f"patched simulated SEP research mode: {t8030}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
