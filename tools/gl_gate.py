#!/usr/bin/env python3
"""Gate on a gitleaks JSON report: exit 1 when any finding is present.

Shared by the CI secrets job and `make scan-secrets`. A clean report is
an empty JSON array ("[]").
"""

from __future__ import annotations

import json
import sys

if len(sys.argv) != 2:
    print("usage: gl_gate.py <gitleaks report.json>", file=sys.stderr)
    sys.exit(2)

with open(sys.argv[1]) as f:
    findings = json.load(f)

if not findings:
    print("PASS  no secrets found")
    sys.exit(0)

print(f"FAIL  gitleaks reported {len(findings)} finding(s):")
for x in findings:
    rule = x.get("RuleID", "?")
    file_ = x.get("File", "?")
    start = (x.get("StartLine") or {}).get("LineNumber", "?")
    print(f"  [{rule}] {file_}:{start} — {x.get('Description', '')[:120]}")
sys.exit(1)
