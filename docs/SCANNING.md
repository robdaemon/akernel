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
committed credentials. The working-tree scan initially flagged 2
`generic-api-key` hits — lwIP upstream's dummy SNMPv3 auth keys in
`third_party/lwip` (contrib/examples/snmp + src/include/lwip/apps).
Ledger decision: **allowlisted via `paths = [third_party/]`** in
`.gitleaks.toml` because `third_party/*` is fetched, sha256-verified,
gitignored upstream code (never part of the repo; only
`third_party/patches/` is tracked) — see the rule "no vendored code in
git" in AGENTS.md. The allowlist stays empty for anything that is, or
could become, a tracked repo credential.

Re-run on every push/PR in CI and locally via `make scan-secrets`.

## Baseline: Ada/SPARK proof status

_Recorded 2026-09-07. GNATprove 16.1.0 + gnat_riscv64_elf 16.1.0
installed via `alr install` (analysis toolchain only — the build stays
on the pinned 15.3.1 crates). Run through `alr exec` so gprconfig
resolves the cross `light-rv64imafdc` runtime._

**Feasibility determination (first real proof):** GNATprove can analyze
the kernel project. Required setup: `XDG_CONFIG_HOME`/`XDG_RUNTIME_DIR`
pointing at the alr config that holds the toolchain selection; invoke
as `alr exec -- gnatprove -P akernel.gpr -f --mode=prove --level=1
--timeout=30 --report=all`; a package body defaults to `SPARK_Mode =>
Off` even when its spec is On, so the body must declare On explicitly.

**Scope of the v1 proof subset — `Kernel.Capabilities`:** spec declares
`pragma SPARK_Mode (On)`; `To_Rights` carries a component-by-component
bit↔rights postcondition and `To_Mask` a no-bits-outside-valid-mask
postcondition. The body is On, and every physmap/PMM/pointer path
(`Page_At`, `Get`, `Put`, `Zero_Page`, `Ensure_Page`, `Release_Page`,
`Insert`, `Insert_At`, `Lookup`, `Duplicate`, `Close`, `Reset`) is
explicitly `SPARK_Mode (Off)` — those are exercised by the in-guest
capability fuzz suite instead of proof.

**Result (level 1, timeout 30 s): all checks proved — 17/17, 0
unproved, 0 justified.**

| Check class | Count | Notes |
|---|---|---|
| Functional contracts | 2 | `To_Rights` and `To_Mask` postconditions, CVC5 |
| Run-time checks | 8 | incl. `Page_No`/`Slot_No` range bounds |
| Initialization (flow) | 1 | plus termination proved on analyzed units |
| Flow errors | 0 | across all 34 analyzed units (whole project) |

Full per-unit report: `obj/development/riscv64/qemu_virt_riscv64/gnatprove/gnatprove.out`.
Kernel build after the annotation: warning-free (`make kernel`).

**Audit-checklist entries (unproved-by-design, not proof failures):**
the SPARK_Mode-Off body paths above; each is covered by the directed
`Tests/Fuzz` capability cases and the cap-accounting rules in AGENTS.md.

**Roadmap (follow-up milestones):** annotate the grant-list validation
in the spawn syscall path next (pure logic, same pattern), then model
`Cap_Table` state invariants (count/root coherence) to lift
`Insert`/`Lookup`/`Close` out of Off — the PMM frame model is the long
pole. Re-run this baseline on each change to `kernel-capabilities.*`.

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

GNATprove (proof baseline): install a version-aligned pair with
`alr install gnatprove gnat_riscv64_elf` (e.g. 16.1.0 — analysis-only;
the build keeps its pinned 15.3.1 crates), then run through `alr exec`
so the cross `light-rv64imafdc` runtime resolves:

```bash
alr exec -- gnatprove -P akernel.gpr -f --mode=prove --level=1 \
  --timeout=30 --report=all
```
