# Shell scripting

Milestone 70 gives the shell an AmigaDOS-subset script language.
One interpreter core — `Scripting.Interp` in
`userspace/scripting/` — serves two hosts:

- the shell's **`execute <script> [args]`** builtin (and batch
  mode, `Shell execute <script> [args]`, which exits with the
  script's last RC), and
- **`Sys:C/Execute <script> [args]`**, the command form for
  programs. `run Sys:C/Execute <script>` backgrounds a script as
  a reapable job (`wait` composes its RC with failat).

Command lines inside a script dispatch through the host: in the
shell they are exactly what you could type (builtins included —
`run`, `jobs`, `wait`, nested `execute`); under C:Execute they
go through the same `Scripting.Exec` engine (pipelines and
redirection included). A nested `execute` re-enters the
interpreter with Depth + 1; C:Execute is its own process and
starts a fresh nesting budget.

## File format

- LF-separated lines; a trailing CR is stripped. A raw line over
  256 bytes is silently skipped (milestone-42 parity).
- `;` in column 1 starts a comment line. No trailing comments.
- Script size cap: 16 KiB. Nesting (a script executing a
  script): 4 levels.
- Keywords are case-insensitive (`ENDIF` == `endif`).
- After every executed command line the script stops when the
  command's RC >= the current failat (default 10) — the Amiga
  convention. Interpreter errors (see below) abort regardless of
  a raised failat.

## Variables and substitution

Scripts have **locals** (per-run, gone when the script ends) and
fall back to **ENV:** (the global variable files):

```
.key a,b,c        ; positional args bind to a, b, c
.def b=default    ; used when the caller gave no arg for b
.set a text here  ; set local a mid-script (rest of line, trimmed)
.set a            ; clear a to defined-empty
```

`.key`/`.k` and `.def` are header directives: recognized only
before the first command line. A local holding no text is
*defined-empty* — it substitutes as nothing. Sixteen locals max
(names <= 32 chars, values <= 128).

Substitution happens on every executed line, before dispatch:

```
<name>      the local, else ENV:<name>
<$name>     ENV: only
```

An undefined reference is a hard error — `bad substitution:
<name>`, RC 10, the script aborts. `<` only opens a reference
when immediately followed by a letter/`_`/`$` AND closed by `>`
on the same line, so `< file` redirection and `echo a<b` stay
literal. The expanded line is capped at 512 bytes.

`set`/`get`/`unset` remain the external ENV: commands — they do
not touch script locals.

## Keywords

### if / else / endif

```
if <command line>        true iff the command's RC < failat
                         (the RC is consumed: it does not trip
                         failat itself)
if not exists <path>     Stat-based; true for directories too
if <a> eq <b>            string compare, case-insensitive;
if not 7 gt 3 val        ops: eq ne gt ge lt le; trailing `val`
                         forces numeric
if                       bare: tests the condition flag (set by
if not                   every if, and by ask)
else
endif
```

- Nesting: 8 deep. `else`/`endif` without an `if`, and an
  unclosed `if` at end of script, are errors (RC 10).
- Lines inside a not-taken block are never expanded — a
  `<undefined>` there does not abort the script.
- Nested ifs inside a skipped block still balance (their
  conditions are not evaluated).

### lab / skip

```
lab top
skip top         ; jump forward to the lab line
skip top back    ; search backwards instead
```

`lab` is a no-op marker. `skip` searches the script text for
`lab <name>` (case-insensitive) and continues there; an unknown
label is RC 10. **Skip abandons any open if frames** — the
classic loop idiom relies on it:

```
lab top
if exists BD0:STEPC
else
echo c > BD0:STEPC
skip top back
endif
```

### quit / failat

```
quit           ; stop the script, RC 0
quit 7         ; stop, RC 7
failat 21      ; commands may return up to 20 without aborting
```

An inner script's `quit 20` returns 20 to the outer script's
`execute` line, which the outer failat judges like any command.

### echo

```
echo hello there          ; internal fast path, prints + newline
echo prompt:  noline      ; no trailing newline
echo hello there > file   ; a line with |, > or < falls through
                          ; to C:Echo, so redirection composes
```

### ask

```
ask proceed?       ; prints the prompt, reads one line
if                 ; y/Y sets the condition flag
echo yes
endif
```

RC is 0 on yes, 5 (RC_Warn) on anything else — below the default
failat, so a "no" does not abort. The reply comes from the host:
the shell reads the raw console stream; C:Execute reads **stdin**
(the redirection trailer applies), so `echo y | Execute script`
answers it from a pipe.

## Errors that abort a script (RC 10)

`bad substitution: <name>` · `script line too long` · `too many
locals` · `bad local name` · `local value too long` · malformed
`.key`/`.def`/`.set` · `if nested too deep (8)` · `else without
if` · `endif without if` · `missing endif` · `label not found` ·
`usage: skip/failat/quit` violations · `scripts nested too deep`
· `can't open/read script` · `script too big`.

## Differences from AmigaDOS

- No quoting anywhere (args and values are whitespace-separated).
- No `.bra`/`.ket`; no `/a` switch parameters in `.key`.
- `skip` resets the if stack (see above).
- `failat` with no argument is an error rather than a query.
- No ARexx.

## Where things live

- `userspace/scripting/scripting-interp.*` — the interpreter
  core (generic over the host's command dispatcher + ask reader).
- `userspace/scripting/scripting-exec.*` — the stage/spawn/reap
  and pipeline engine shared by the shell and C:Execute.
- `userspace/scripting/scripting-console_io.*` — the shell's
  blocking console line reader for `ask`.
- `userspace/shell/shell.adb` — the `execute` builtin, batch
  mode, job control.
- `userspace/execute/execute.adb` — C:Execute.
