# Appendix — checks that cannot fail

**2026-11-20.** Ten assertions in this repository reported `ok` against a
working tree where the defect they were meant to catch was still present. Six
were written during this session; four predate it. Every one was found by
*mutating* the check and watching it stay green — none by reading it.

This appendix records the four shapes, because the shapes recur and the
individual fixes do not generalise.

## Why this is the failure mode that matters here

This repository's method is gates. `tests/` is 247 files and 48,671 lines
against 135,151 lines of R — roughly a third of the code exists to refuse bad
results. A gate that cannot fail is worse than a missing gate: a missing gate
is visibly missing, while a gate that always passes is counted as coverage, is
cited in a badge, and is believed.

The shapes below are ordered by how long each one hid.

---

## Shape 1 — a check gated behind something that is never there

`tests/test_appendix_matches_artifacts.R` opened with a guard: if the
agreement artifact is absent, print a skip and `quit(status = 0)`. The
artifact is gitignored, so it is absent in *every* fresh checkout — every CI
runner, nightly included. Twelve figure-style assertions sat below that guard
and had never run. The file printed `PASS (0 failures)` for them.

The fix is ordering, not logic: the assertions that need no artifact were
moved **above** the guard, and the guard now reports what the checks above it
found. Proved by mutation — a rogue `ggsave()` planted in a figure script
turned the reordered file red and left the committed one green.

**The tell:** a `quit(status = 0)` or an early `return()` above an assertion
block, conditioned on an input the runner does not have.

## Shape 2 — a predicate that matches text where a token was meant

Four separate instances, all the same error:

| where | what it matched | what it meant |
|---|---|---|
| a transform's file filter | `"fails <- 0L"` as a substring | the line `fails <- 0L`, not `xfails <- 0L` |
| `P3a` | the opening of a definition | the whole definition — the file it accused continues `%>% transmute(...)`, so it reads *and* projects |
| `P4b` | `test_file("tests/X.R"` stripped of its opening quote only | a path — the trailing `"` made every `file.exists()` false, so the scan ran over an empty list |
| `Q4a` (first draft) | `||` and `TRUE` on one line | a tautology, which in the real case was written `cond ||\n  TRUE` |

**The tell:** `grepl(..., fixed = TRUE)` or a substring test standing in for a
line-anchored or token-anchored match. When the subject is code, anchor it.

## Shape 3 — a scan that claims more than it reads

A git pathspec of `"*.R"` does not cross directory boundaries. It returns 267
paths here; the repository tracks 647. Three scans were reading only the
top-level scripts while their messages said *no tracked R file*. Two more
read an empty list because their input parser left a quote on every path.

**The tell:** a scan reporting a clean result without ever asserting that its
input set was non-empty and of the expected magnitude. `Q1a` and `P4a2` exist
only to make an empty scan distinguishable from a clean tree.

## Shape 4 — a condition wired so it cannot be false

Four of these predate this session and are baselined in
`tests/test_gate_integrity_saboteurs.R`:

- `tests/test_borrowed_isochrones_saboteurs.R:84` — `chk(TRUE, "C7 skipped: ...")`.
  A skip printed as a pass, in a file named for catching exactly that.
- `tests/test_metamorphic_invariance.R:257` — `chk(TRUE, "D1 a duplicated
  column name is REJECTED at read time")`. Claims a rejection without checking
  that one happened.
- `tests/test_cross_vintage_pairing_saboteurs.R:126` — computes a condition and
  discards it with `|| TRUE`.
- `tests/test_amcb_gates.R:101` — `chk(TRUE, sprintf(... %d ...))`. Reports a
  count dressed as an assertion; `checked > 0L` is the assertion it looks like
  it is making.

Rewriting these changes what each suite asserts, which belongs to whoever
wrote it. The baseline refuses a *fifth* and `Q4a2` fails the moment one is
fixed, so the list shrinks rather than rots.

A fifth instance was mine: a gate ending `|| TRUE`, written to express "this
is informational", which silently made the whole assertion unfailable.

---

## What now polices each shape

| shape | gate | file |
|---|---|---|
| 1 — gated behind an absent input | the guard reports what ran above it | `tests/test_appendix_matches_artifacts.R` |
| 2 — text where a token was meant | `P3e`, `P4a2`, `Q4b` hold the distinction | `tests/test_ponytail_cuts_saboteurs.R`, `tests/test_gate_integrity_saboteurs.R` |
| 3 — a scan narrower than its claim | `Q1a`, `Q2a`, `P4a2` | `tests/test_gate_integrity_saboteurs.R` |
| 4 — a condition that cannot be false | `Q4a`, `Q4a2` with a shrink-only baseline | `tests/test_gate_integrity_saboteurs.R` |
| — a pattern that never compiles | `Q1b`, across all 647 tracked `.R` files | `tests/test_gate_integrity_saboteurs.R` |
| — a generated sidecar swept into a commit | `Q3a` | `tests/test_gate_integrity_saboteurs.R` |

Each of those is mutation-proved **in both directions**: it fires on the
defect, and it stays quiet on the legitimate case beside it. `Q1d` admits a
PCRE lookbehind; `Q2c` admits a directory-qualified glob; `Q3c` admits a
sidecar changed next to its own artifact; `P3e` admits a reader that goes on
to project.

## Three habits this cost

1. **Add before you run.** `ci_hygiene` H4 reads `git ls-files`. Running it on
   an untracked new file reports a pass that CI will not reproduce — which is
   how a duplicate `slurp` reached a pull request today.
2. **A scanner must not be able to find its own needle.** Three suites accused
   themselves once their scans widened. Needles that would match the scanner's
   own source are assembled at runtime (`paste0("library(", "here)")`), never
   spelled.
3. **Verify that a check can fail, not that it passes.** Writing the assertion
   is not the work. Breaking the thing it guards, and watching it go red, is.

## See also

- `tests/test_gate_integrity_saboteurs.R` — the four shapes, gated
- `tests/test_ponytail_cuts_saboteurs.R` — the cuts those gates protect
- `NEWS.md`, 2026-11-20 — what moved, and what was retracted
