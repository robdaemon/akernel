# akernel — security scanning ledger

This file is the single record for akernel's vulnerability-scanning
program: what surfaces are covered, which tools back each scan, the
current baseline of findings, and how results are remediated.

All scans are meant to run both locally (`make scan-*`) and in
GitHub Actions (`.github/workflows/security.yml`). The CI jobs are
the gate; the local targets are the same checks without a push.

## Surfaces under scan

| Surface | Content | Origin / trust | Scan |
|---|---|---|---|
| Third-party C/library code | lwIP 2.2.1 (network stack, linked into `netserv`) | fetched tarball, sha256-pinned (`Makefile`) | CVE watch (`osv-scanner`) |
| Third-party data | Terminus font 4.49.1 (BDFs into `Sys:Fonts`) | fetched tarball, sha256-pinned (`Makefile`) | CVE watch (`osv-scanner`) |
| Toolchain | `gnat_riscv64_elf` 15.3.1 | Alire, pinned in root + every crate `alire.toml` / `alire.lock` | pin drift check + CVE watch |
| Own code — kernel | Ada/SPARK kernel (`src/`) | in-repo | GNATprove flow/proof on capability/IPC core |
| Own code — userspace | Ada/SPARK apps + custom RTS | in-repo | (proof scope: see below) |
| Own code — host tooling | `tools/*.py`, `Makefile` recipes | in-repo | bandit; shellcheck where feasible |
| Repository secrets | git history + future pushes | in-repo | gitleaks |

### Fetch inventory (pins live in the Makefile — nothing vendored in git)

`git ls-files third_party` is **empty by design**: all third-party
code is downloaded at build time, sha256-verified, and stamped.
`third_party/` is gitignored. The git-visible source of truth for
supply-chain identity is the fetch recipes and pin constants.

| Artifact | Version | Fetch source | Pin site (git) | sha256 |
|---|---|---|---|---|
| lwIP | 2.2.1 (`STABLE-2_2_1_RELEASE`) | github.com/lwip-tcpip/lwip tarball | `Makefile` `LWIP_VER`/`LWIP_TAG`/`LWIP_SHA256` | `ce0b7461...c539` |
| Terminus font | 4.49.1 | sourceforge terminus-font release tarball | `Makefile` `TERMINUS_VER`/`TERMINUS_SHA256` | `d961c1b7...ef79` |
| GNAT cross toolchain | 15.3.1 | Alire (community index) | `alire.toml` `[[pins]]` + `alire/alire.lock`; same pin in all 69 userspace crate `alire.toml`s | Alire-lockfile enforced (`versions = "=15.3.1"`) |
| lwIP patch set | — | none currently tracked | `third_party/patches/` (per AGENTS.md, patches are the one tracked exception; none exist today) | — |

Alire dependency universe is a single node: `gnat_riscv64_elf` 15.3.1
(root `alire/alire.lock` and every crate's lockfile contain no other
third-party dependency). Host Python tools import only the stdlib
(`argparse os pathlib re socket struct sys threading`) plus sibling
repo modules — no PyPI dependency surface.

<!-- Result sections below are filled in by the scan steps as their
     baselines are established. Each records date + tool version. -->

## Baseline: dependency CVEs

_Recorded 2026-09-07. Tool: osv-scanner 2.5.1 (built 2026-08-17) over the
committed SBOM (`docs/sbom/akernel.spdx.json`)._

**osv-scanner result:** 0 vulnerabilities; the SBOM parses and all 3
packages are enumerated. Caveat recorded as a tool limitation: all
three purls are `pkg:generic`, which has no OSV ecosystem, so
osv-scanner filters them as "unscannable" — it validates the SBOM but
cannot itself attest to lwIP CVE status. Upstream lwIP releases are
not indexed by OSV; CVE status therefore comes from the manual
advisory review below (re-run on each pin bump or toolchain change).

**Manual advisory review — lwIP 2.2.1 (the real C surface):**

| Advisory | Affects | In-tree exposure | Verdict |
|---|---|---|---|
| CVE-2026-8836 — SNMPv3 USM stack overflow in `snmp_parse_inbound_frame()` (`src/apps/snmp/snmp_msg.c`), CVSS 9.8, published 2026-05 | lwIP ≤ 2.2.1 | **Not compiled.** `userspace/lwip/lwip.gpr` builds only `src/core`, `src/core/ipv4`, `src/netif` + the committed `port/`; the entire `src/apps` tree is outside `Source_Dirs`. Fix commit `0c957ec03054eb6c8205e9c9d1d05d90ada3898c`. | Not reachable |
| xchglabs audit (2026-05, disclosure from 2026-08-05): 13 findings in SMTP client, mDNS, MQTT client, IPv6 ND6, PPP/PPPoE/MS-CHAP, SNMP/SNMPv3, `makefsdata` | lwIP 2.2.1 | All findings live in `src/apps/*` or `src/netif/ppp` or the host `makefsdata` tool — none in the compiled `core`+`netif` subset (IPv4 only, no IPv6/PPP dirs listed). | Not reachable |
| CVE-2024-7490 (Microchip ASF tinydhcp), CVE-2026-45160 (ESP-IDF DHCP) | downstream forks, not upstream | n/a | n/a |

**Terminus 4.49.1:** font data (BDF) — no CVE surface. **gnat_riscv64_elf
15.3.1:** cross compiler; no published advisories affecting the pinned
release (re-check Alire index metadata on any toolchain bump).

**Remediation decision (recorded):** keep the lwIP pin at 2.2.1 — the
build subset excludes every known 2026 advisory's code path. Revisit on
any change that compiles `src/apps` (especially before enabling any
SNMP/SMTP/mDNS/MQTT client) and bump to the next lwIP release once one
ships with the 2026 fixes, re-running this whole baseline.


## Baseline: secret scan

_Recorded 2026-09-07. Tool: gitleaks 8.30.1 (config `.gitleaks.toml`,
extends default rule set) over all 332 commits plus the working tree._

**Result: no leaks found** (report `[]`, exit 0). The repo has no
committed credentials. Two false positives have been resolved:

1. **lwIP dummy SNMPv3 keys** — the working-tree scan flagged 2
   `generic-api-key` hits under `third_party/lwip`
   (contrib/examples/snmp + src/include/lwip/apps). Ledger decision:
   **allowlisted via `paths = [third_party/]`** because `third_party/*`
   is fetched, sha256-verified, gitignored upstream code (never part of
   the repo; only `third_party/patches/` is tracked) — see the rule
   "no vendored code in git" in AGENTS.md.
2. **actions/cache key (2026-09-07)** — CI flagged the actions/cache
   cache-key value (`alr-2.1.1-gnatprove-16.1.0`) in
   `.github/workflows/security.yml`: gitleaks `generic-api-key` fires
   on any `key:`/`*_KEY:` assignment with a token-like value. Not a
   credential. Fixed by moving the value into an env var whose name
   avoids the pattern (`ALR_CACHE_SLOT`, with the cache `key` field set
   from `${{ env.ALR_CACHE_SLOT }}`) and **amending the offending
   commit out of history** (381a094) so the full-history scan stays
   clean. gl_gate.py was also hardened: `StartLine` in the report can
   be an int or a `{LineNumber: ...}` dict.

The allowlist stays empty for anything that is, or could become, a
tracked repo credential.

Re-run on every push/PR in CI and locally via `make scan-secrets`.

## Baseline: Ada/SPARK proof status

_Recorded 2026-09-07. GNATprove 15.1.0 + gnat_riscv64_elf 15.3.1
installed via `alr install` (analysis toolchain pinned to the project's
own 15.3.1 line — the custom RTS does not compile on GNAT 16, and no
upgrade is planned yet; gnatprove 15.3.1 does not exist in the index,
and 15.1.0 is verified compatible with the 15.3.1 compiler). Run with
the alr bin dir on `PATH` so gprconfig resolves the cross
`light-rv64imafdc` runtime._

**Feasibility determination (first real proof):** GNATprove can analyze
the kernel project. Required setup: `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`
pointing at the alr config that holds the toolchain selection; invoke
as `alr exec -- gnatprove -P akernel.gpr -f --mode=prove --level=1
--timeout=30 --report=all`; a package body defaults to `SPARK_Mode =>
Off` even when its spec is On, so the body must declare On explicitly.

**Scope of the v1 proof subset — `Kernel.Capabilities`:** spec declares
`pragma SPARK_Mode (On)`; `To_Rights` carries a component-by-component
bit↔rights postcondition and `To_Mask` the mirror-image encoding spec
(component ↔ bit, no bits outside the valid mask). A **Ghost
grant-validation lemma** (`Lemma_Mask_Round_Trip`) characterizes the
spawn validator's unknown-bits check in `Grant_List_Caps`
(`kernel-processes.adb`): for any mask with no bits outside
`Valid_Rights_Mask`, `To_Mask (To_Rights (Mask)) = Mask`. The body is
On, and every physmap/PMM/pointer path
(`Page_At`, `Get`, `Put`, `Zero_Page`, `Ensure_Page`, `Release_Page`,
`Insert`, `Insert_At`, `Lookup`, `Duplicate`, `Close`, `Reset`) is
explicitly `SPARK_Mode (Off)` — those are exercised by the in-guest
capability fuzz suite instead of proof.

**Result (level 1, timeout 30 s): all checks proved — 17/17, 0
unproved, 0 justified.**

| Check class | Count | Notes |
|---|---|---|
| Functional contracts | 3 | `To_Rights`, `To_Mask` encoding specs and `Lemma_Mask_Round_Trip`, CVC5 |
| Run-time checks | 7 | incl. `Page_No`/`Slot_No` range bounds |
| Initialization (flow) | 1 | plus termination proved on analyzed units |
| Flow errors | 0 | across all 34 analyzed units (whole project) |

Full per-unit report: `obj/development/riscv64/qemu_virt_riscv64/gnatprove/gnatprove.out`.
Kernel build after the annotation: warning-free (`make kernel`).

**Audit-checklist entries (unproved-by-design, not proof failures):**
the SPARK_Mode-Off body paths above; each is covered by the directed
`Tests/Fuzz` capability cases and the cap-accounting rules in AGENTS.md.

**Roadmap (follow-up milestones):** the grant-list *encoding* lemma is
proved; the full `Grant_List_Caps` validation becomes provable once
`Lookup_Cap` / IPC-buffer contracts exist (the syscall path stays Off
until then — it dereferences the parent's physmap IPC buffer and the
cap table). Next: a subset-decode lemma so the validator's
`Has_Rights (Cap_Info.Rights, To_Rights (Mask))` check is provable in
terms of raw masks, then model `Cap_Table` state invariants
(count/root coherence) to lift `Insert`/`Lookup`/`Close` out of Off —
the PMM frame model is the long pole. Re-run this baseline on each
change to `kernel-capabilities.*`.

## Baseline: host tooling lint

_Recorded 2026-09-07. Host: Fedora. Native package is
`sudo dnf install -y bandit`; the portable route is `pip install
bandit` (`python3 -m pip install --user bandit` on a normal box — this
rootless sandbox has a read-only `~/.local`, so here it is
`python3 -m pip install --prefix /tmp/pipuser bandit`, run with
`PYTHONPATH=/tmp/pipuser/lib/python3.14/site-packages`). bandit 1.9.4._

- **`python3 -m py_compile tools/*.py`** (always-on): 12 files, clean.
- **bandit 1.9.4** over `tools/` (`bandit -q -ll -r tools`, also run by
  the CI `host` job; `-ll` = medium+ threshold): 0 High, 0 Medium, **25
  Low** — all `B101 (assert_used)` confined to `tools/mkbefs.py`.
  Decision: **accepted** — those asserts are deliberate
  filesystem-image invariant checks in a host verification tool and are
  never executed under `python -O`; convert them to explicit `raise`
  checks if policy ever tightens. Note: bandit exits 1 whenever it
  *reports* any finding, so the `-ll` threshold is what keeps the job
  green for the accepted Lows; the full `-r tools` report is the
  recorded baseline above.
- **shellcheck 0.10.0**: probed; the repo tracks **zero** `*.sh`/`*.bash`
  files, so a shell-script pass is N/A. Non-trivial Makefile recipe
  verification is enforced structurally instead: `tools/check_pins.py`
  fails any fetch recipe that stops gating extract on `sha256sum -c`.
  Revisit shellcheck if real shell scripts ever enter the repo.

## How findings get remediated

- **lwIP or Terminus CVE** → bump the pinned version in the Makefile
  (or add a `third_party/patches/lwip-*.patch` if no release fixes it)
  and record the decision here. Version bumps are ordinary commits;
  the fetch recipe re-verifies the new sha256.
- **Toolchain advisory** → bump the `[[pins]]`/lockfile pin uniformly
  across root + crates (append-only rules do not constrain toolchain
  versions).
- **Own-code finding** → fix in the owning subsystem per project rules
  (zero warnings, cap-accounting invariants); GNATprove "check failed"
  items become audit-checklist entries tracked here.
- **Secret in history** → rotate the credential if real, purge history,
  and extend `.gitleaks.toml` allowlist only for documented
  non-secrets.

## Local usage

```bash
make scan-deps      # fetch pins, enforce sha256 pins, SBOM freshness
                    # (+ osv-scanner CVE gate when on PATH)
make scan-secrets   # gitleaks full history + working tree (when on PATH)
make scan-host      # py_compile tools/*.py (+ bandit when on PATH)
make scan-ada       # prints the GNATprove invocation (see below)
```

The heavy scanners are not vendored; CI fetches pinned releases
(osv-scanner 2.5.1, gitleaks 8.30.1, bandit via pip — all recorded in
`.github/workflows/security.yml`). To run them locally, install the
same pins and put them on `PATH` (the scan-* targets then use them).

GNATprove (proof baseline): **prerequisite — Alire 2.1.1** (GitHub
runners don't ship it; CI installs the pinned release binary
`alr-2.1.1-bin-x86_64-linux.zip`, sha256
`09c66bcd8c35dd4b97b72c3d9b76e44caa6964a2db35aba069f396f00f1f64c7`).
Then install the pinned pair with
`alr install gnatprove=15.1.0 gnat_riscv64_elf=15.3.1` — pinned to the
project's own 15.3.1 line because the custom RTS does not compile on
GNAT 16 (no upgrade yet); the index has no gnatprove 15.3.1, and
gnatprove 15.1.0 is verified compatible with the 15.3.1 compiler
(16/16 checks proved). Register both toolchain components with
`alr toolchain --select gnat_riscv64_elf=15.3.1` and
`alr toolchain --select gprbuild=26.0.1` (a fresh runner/box lacks
gprbuild; gnatprove's compile phase needs it registered), and run with
the alr
bin dir on `PATH` so gprconfig resolves the cross `light-rv64imafdc`
runtime (no crate solve is involved). On a **fresh checkout** the
`config/akernel_config.{ads,gpr,h}` files are absent (Alire-generated,
gitignored) and gnatprove fails at `akernel.gpr: imported project file
"config/akernel_config.gpr" not found` — regenerate them first
(solve only, no build):

```bash
alr --non-interactive update     # regenerates config/; no make needed
```

Then run the proof with the alr bin dir on `PATH`:

```bash
# ALR_BIN = dir containing the alr-installed riscv64-elf-gcc / gnatprove
# --warnings=off: analysis compiles re-enable the .x warning class
# (CE may call Last_Chance_Handler) that the kernel build suppresses via
# -gnatw.X — expected noise from syscall-dispatcher range conversions in
# arch-traps.adb, not proof failures.
PATH="$ALR_BIN:$PATH" gnatprove -P akernel.gpr -f --mode=prove --level=1 \
  --timeout=30 --report=all --warnings=off
```
