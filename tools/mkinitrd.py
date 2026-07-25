#!/usr/bin/env python3
import argparse
import struct
from pathlib import Path

MAGIC = b"AKRD"
VERSION = 1
HEADER = "<4sIQQ"  # magic, version, cpio_size, reserved


def main() -> None:
    parser = argparse.ArgumentParser(description="Wrap cpio archive in akernel initrd header")
    parser.add_argument("cpio", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    payload = args.cpio.read_bytes()
    header = struct.pack(HEADER, MAGIC, VERSION, len(payload), 0)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(header + payload)

    print(f"wrote {args.output} ({len(header) + len(payload)} bytes, cpio {len(payload)} bytes)")


if __name__ == "__main__":
    main()
