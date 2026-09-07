#!/usr/bin/env python3
"""Deterministic SPDX 2.3 SBOM generator for akernel's supply chain.

Why not syft: akernel's fetch surface is two sha256-pinned tarballs
plus one Alire-pinned toolchain. syft has no Alire ecosystem support
and would only heuristically re-derive what the Makefile pins and the
alire manifests already state authoritatively. This generator reads
that same single source of truth, so the committed SBOM cannot drift
from the pins, and it is deterministic (diff-stable, no network, no
binary tool in CI). Swap in syft later if the surface ever grows an
ecosystem syft understands.

Output: SPDX 2.3 JSON document. Default writes
docs/sbom/akernel.spdx.json (git-committed next to docs/SCANNING.md).

Usage:
  python3 tools/gen_sbom.py                 # regenerate the committed file
  python3 tools/gen_sbom.py --check         # exit 1 if committed file is stale
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

from check_pins import ROOT, expand, makefile_vars

SPDX_VERSION = "SPDX-2.3"
DATA_LICENSE = "CC0-1.0"
OUT = ROOT / "docs" / "sbom" / "akernel.spdx.json"
TOOLCHAIN = "gnat_riscv64_elf"
# Known licenses from the fetched artifacts' own license texts.
LICENSES = {
    "lwip": "BSD-3-Clause",
    "terminus-font": "OFL-1.1",
}
# Makefile variable prefix -> SBOM display name.
DISPLAY = {"LWIP": "lwip", "TERMINUS": "terminus-font"}

# Field whose value is wall-clock time and therefore excluded from the
# deterministic comparison.
VOLATILE = {"created"}


def download_url(recipe_block: str, vars_: dict[str, str]) -> str:
    for line in recipe_block.splitlines():
        m = re.search(r"(https?://\S+)", line)
        if m:
            url = m.group(1).rstrip("\\")
            return expand(url, vars_)
    return "NOASSERTION"


def recipe_block(text: str, var: str) -> str:
    m = re.search(re.escape(f"$({var})") + r":\s*\n((?:\t[^\n]*\n?)*)", text)
    return m.group(1) if m else ""


def make_document(makefile: Path, vars_: dict[str, str], text: str,
                  created: str) -> dict:
    packages = []
    refs = []  # (from, to)
    for name in sorted({v[: -len("_TARBALL")] for v in vars_
                        if v.endswith("_TARBALL")}):
        tvar = f"{name}_TARBALL"
        ver = vars_.get(f"{name}_VER", "NOASSERTION")
        pin = vars_.get(f"{name}_SHA256", "")
        rel = Path(expand(vars_[tvar], vars_)).name
        pkg = {
            "SPDXID": f"SPDXRef-Package-{name}",
            "name": DISPLAY.get(name, name.lower()),
            "versionInfo": ver,
            "downloadLocation": download_url(recipe_block(text, tvar), vars_),
            "filesAnalyzed": False,
            "licenseConcluded": LICENSES.get(name, "NOASSERTION"),
            "licenseDeclared": LICENSES.get(name, "NOASSERTION"),
            "copyrightText": "NOASSERTION",
            "supplier": "NOASSERTION",
            "externalRefs": [{
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": f"pkg:generic/{name}@{ver}",
            }],
        }
        if re.fullmatch(r"[0-9a-fA-F]{64}", pin):
            pkg["checksums"] = [{
                "algorithm": "SHA256",
                "checksumValue": pin,
            }]
        packages.append(pkg)
        refs.append(("SPDXRef-DOCUMENT", pkg["SPDXID"]))
    # Alire toolchain.
    tool = {
        "SPDXID": "SPDXRef-Package-gnat_riscv64_elf",
        "name": TOOLCHAIN,
        "versionInfo": "15.3.1",
        "downloadLocation": "https://alire.ada.dev",
        "filesAnalyzed": False,
        "licenseConcluded":
            "GPL-3.0-or-later AND GPL-3.0-or-later WITH GCC-exception-3.1",
        "licenseDeclared":
            "GPL-3.0-or-later AND GPL-3.0-or-later WITH GCC-exception-3.1",
        "copyrightText": "NOASSERTION",
        "supplier": "Organization: AdaCore",
        "externalRefs": [{
            "referenceCategory": "PACKAGE-MANAGER",
            "referenceType": "purl",
            "referenceLocator": f"pkg:generic/{TOOLCHAIN}@15.3.1",
        }],
    }
    packages.append(tool)
    refs.append(("SPDXRef-DOCUMENT", tool["SPDXID"]))
    packages.sort(key=lambda p: p["SPDXID"])

    # Deterministic namespace: content-addressed on the package list.
    digest = hashlib.sha256(
        json.dumps(packages, sort_keys=True).encode()).hexdigest()[:16]
    doc = {
        "SPDXID": "SPDXRef-DOCUMENT",
        "spdxVersion": SPDX_VERSION,
        "creationInfo": {
            "created": created,
            "creators": ["Tool: akernel tools/gen_sbom.py"],
        },
        "name": "akernel",
        "dataLicense": DATA_LICENSE,
        "documentNamespace":
            f"https://github.com/robdaemon/akernel/spdx/{digest}",
        "documentDescribes": [p["SPDXID"] for p in packages],
        "packages": packages,
        "relationships": [{
            "spdxElementId": frm,
            "relationshipType": "CONTAINS",
            "relatedSpdxElement": to,
        } for frm, to in refs],
    }
    return doc


def normalize(doc: dict) -> dict:
    doc = json.loads(json.dumps(doc, sort_keys=True))
    doc.get("creationInfo", {}).pop("created", None)
    return doc


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare against the committed file, exit 1 if stale")
    ap.add_argument("--created",
                    default=datetime.datetime.now(
                        datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    help="creationInfo.created timestamp (ISO-8601)")
    args = ap.parse_args()

    makefile = ROOT / "Makefile"
    text = makefile.read_text()
    vars_ = makefile_vars(text)
    doc = make_document(makefile, vars_, text, args.created)

    if args.check:
        if not OUT.exists():
            print(f"FAIL  {OUT} missing — run tools/gen_sbom.py", file=sys.stderr)
            return 1
        committed = json.loads(OUT.read_text())
        if normalize(doc) == normalize(committed):
            print(f"PASS  {OUT} is current")
            return 0
        print(f"FAIL  {OUT} is stale — rerun tools/gen_sbom.py", file=sys.stderr)
        return 1

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(doc['packages'])} packages)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
