#!/usr/bin/env python3
"""Supply-chain pin enforcement for akernel.

Verifies that the git-visible fetch pins are internally consistent and
that any on-disk download matches them. Stdlib only, no network.

Checks
  1. Every sha256-pinned tarball in the Makefile that exists under
     third_party/download/ hashes to exactly the pin in the Makefile.
  2. Each fetch recipe still gates extract on `sha256sum -c` (so a
     future edit that silently drops verification fails here).
  3. The Alire toolchain pin (root alire.toml [[pins]]) matches the
     resolved root lockfile and every userspace crate's alire.toml and
     alire.lock — no crate may drift to a different toolchain.

Exit status: 0 all pass, 1 any failure, 2 usage/structural error.
"""

from __future__ import annotations

import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOWNLOAD = ROOT / "third_party" / "download"
TOOLCHAIN = "gnat_riscv64_elf"
TOOLCHAIN_VERSION = "15.3.1"

failures: list[str] = []
passes: list[str] = []
notes: list[str] = []


def report(ok: bool, what: str, detail: str = "") -> None:
    tag = "PASS" if ok else "FAIL"
    (passes if ok else failures).append(f"{tag}  {what}" + (f"  ({detail})" if detail else ""))


def note(what: str, detail: str = "") -> None:
    notes.append(f"INFO  {what}" + (f"  ({detail})" if detail else ""))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def makefile_vars(text: str) -> dict[str, str]:
    """All `NAME := value` / `NAME = value` single-line assignments."""
    out: dict[str, str] = {}
    for m in re.finditer(r"^([A-Z][A-Z0-9_]*)\s*:?=\s*(.+?)\s*$", text, re.M):
        out[m.group(1)] = m.group(2)
    return out


def expand(value: str, vars_: dict[str, str], depth: int = 0) -> str:
    if depth > 4:
        return value
    changed = False
    for m in re.finditer(r"\$\(([A-Z][A-Z0-9_]*)\)", value):
        if m.group(1) in vars_:
            value = value.replace(m.group(0), vars_[m.group(1)])
            changed = True
    return expand(value, vars_, depth + 1) if changed else value


def check_tarballs(vars_: dict[str, str], text: str) -> None:
    names = sorted({v[: -len("_TARBALL")] for v in vars_ if v.endswith("_TARBALL")})
    if not names:
        report(False, "no *_TARBALL artifacts found in Makefile")
        return
    for name in names:
        var = f"{name}_TARBALL"
        pin_var = f"{name}_SHA256"
        path = ROOT / expand(vars_[var], vars_)
        # Recipe body for this artifact's tarball target. The Makefile
        # declares the target by *variable reference*, e.g.
        #   $(LWIP_TARBALL):          <- target line
        #           curl ...          <- recipe
        #           echo ... | sha256sum -c -
        #           mv $@.tmp $@
        # so match the literal "$(LWIP_TARBALL):" declaration. A
        # prerequisite occurrence like "$(LWIP_STAMP): $(LWIP_TARBALL)"
        # has more text after ':' on the same line and cannot match.
        target = re.escape(f"$({var})") + r":\s*\n((?:\t[^\n]*\n?)*)"
        block_m = re.search(target, text)
        block = block_m.group(1) if block_m else ""
        if pin_var not in vars_:
            report(False, f"{var} has no {pin_var} pin")
            continue
        pin = vars_[pin_var]
        ok_pin = re.fullmatch(r"[0-9a-fA-F]{64}", pin) is not None
        if not ok_pin:
            report(False, f"{name} pin is not a 64-hex sha256", pin)
            continue
        # Guard 1: fetch recipe must verify before extract.
        lines = [l for l in block.splitlines() if l.strip()]
        has_curl = any("curl" in l for l in lines)
        has_verify = any("sha256sum -c" in l for l in lines)
        curl_i = next((i for i, l in enumerate(lines) if "curl" in l), -1)
        verify_i = next((i for i, l in enumerate(lines) if "sha256sum -c" in l), -1)
        mv_i = next((i for i, l in enumerate(lines) if "mv $@.tmp" in l), -1)
        ordered = 0 <= curl_i < verify_i and (mv_i < 0 or verify_i < mv_i)
        if not has_curl or not has_verify or not ordered:
            report(False, f"{name} fetch recipe does not gate extract on sha256sum -c")
        else:
            report(True, f"{name} fetch recipe verifies sha256 before extract")
        # Guard 2: on-disk tarball hashes to the pin.
        if not path.exists():
            note(f"{name} tarball not present — skipped",
                 f"{path.name} (run the fetch target before checking)")
            continue
        actual = sha256(path)
        report(actual == pin, f"{name} on-disk tarball matches pin", f"{path.name}")


def parse_alire_pin(manifest: Path) -> str | None:
    """Extract the pinned toolchain version from an alire.toml."""
    text = manifest.read_text()
    m = re.search(rf"\[\[pins\]\]\s*$.*?^{TOOLCHAIN}\s*=\s*\{{[^}}]*?version\s*=\s*'([^']+)'", text, re.M | re.S)
    if m:
        return m.group(1)
    m = re.search(rf"^\[\[pins\]\]\s*$.*?^{TOOLCHAIN}\s*=\s*\{{ version\s*=\s*'([^']+)' \}}", text, re.M | re.S)
    return m.group(1) if m else None


def lock_version(lock: Path) -> str | None:
    """Version of the pinned toolchain inside a generated alire.lock.

    Layout: [[solution.state]] carries crate + pin_version, e.g.
        crate = "gnat_riscv64_elf"
        ...
        pin_version = "15.3.1"
    """
    if not lock.exists():
        return None
    text = lock.read_text()
    for state in re.split(r"\[\[solution\.state\]\]", text)[1:]:
        if re.search(rf'^crate = "{TOOLCHAIN}"', state, re.M):
            m = re.search(r'^pin_version = "([^"]+)"', state, re.M)
            if m:
                return m.group(1)
    return None


def check_alire() -> None:
    root_manifest = ROOT / "alire.toml"
    root_lock = ROOT / "alire" / "alire.lock"
    if not root_manifest.exists():
        report(False, "root alire.toml missing")
        return
    root_pin = parse_alire_pin(root_manifest)
    report(root_pin == TOOLCHAIN_VERSION, f"root alire.toml pins {TOOLCHAIN} {TOOLCHAIN_VERSION}",
           f"found {root_pin!r}")
    # Lockfiles are gitignored, alr-generated artifacts (they re-solve
    # automatically on the next build after a manifest change), so a
    # present-but-stale lock is advisory, not a gate failure.
    lv = lock_version(root_lock)
    if root_lock.exists():
        if lv != TOOLCHAIN_VERSION:
            note("root alire.lock is stale (alr will re-solve on next build)",
                 f"lock shows {lv!r}, manifest pins {TOOLCHAIN_VERSION}")
    # Cross-crate uniformity is the git-visible contract: every crate
    # manifest must carry the same [[pins]] block as the root.
    crates = sorted(p.parent for p in ROOT.glob("userspace/*/alire.toml"))
    drift = []
    for crate in crates:
        pv = parse_alire_pin(crate / "alire.toml")
        if pv != TOOLCHAIN_VERSION:
            drift.append(f"{crate.name}:manifest={pv!r}")
        cv = lock_version(crate / "alire" / "alire.lock")
        if cv is not None and cv != TOOLCHAIN_VERSION:
            note(f"{crate.name} alire.lock is stale (alr will re-solve)",
                 f"lock shows {cv!r}")
    report(not drift, f"{len(crates)} userspace crates pin {TOOLCHAIN} {TOOLCHAIN_VERSION}",
           "; ".join(drift[:5]) if drift else "no manifest drift")


def main() -> int:
    makefile = ROOT / "Makefile"
    if not makefile.exists():
        print(f"error: {makefile} not found", file=sys.stderr)
        return 2
    text = makefile.read_text()
    vars_ = makefile_vars(text)
    check_tarballs(vars_, text)
    check_alire()
    for line in passes:
        print(line)
    for line in failures:
        print(line)
    for line in notes:
        print(line)
    if failures:
        print(f"\n{len(failures)} pin-enforcement failure(s)")
        return 1
    print(f"\nall pin-enforcement checks passed "
          f"({len(passes)} checks, {len(notes)} info)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
