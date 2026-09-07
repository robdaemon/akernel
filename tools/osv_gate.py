#!/usr/bin/env python3
"""Gate on osv-scanner JSON output: exit 1 when findings are present.

osv-scanner's own exit semantics have shifted across major versions, so
the CI deps job and `make scan-deps` both route its `--format json`
output through this helper. Exit 0 means clean (no OSV-mapped
vulnerabilities). See docs/SCANNING.md for the pkg:generic caveat —
this gate cannot attest to lwIP CVE status by itself.
"""

from __future__ import annotations

import json
import sys

if len(sys.argv) != 2:
    print("usage: osv_gate.py <osv-scanner json output>", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1]) as f:
    data = json.load(f)

results = data.get("results") or []
if not results:
    print("PASS  no OSV-mapped vulnerabilities")
    sys.exit(0)

print(f"FAIL  osv-scanner reported {len(results)} finding(s):")
for r in results:
    for v in r.get("vulnerabilities", []):
        pkg = v.get("package", {}).get("name", "?")
        ids = v.get("aliases") or [v.get("id", "?")]
        print(f"  {pkg}: {', '.join(ids)} — {v.get('summary', '')[:140]}")
sys.exit(1)
