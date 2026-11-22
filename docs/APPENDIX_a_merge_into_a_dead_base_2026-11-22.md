# A merge into a dead base, and four other things that were not checked

**2026-11-22.** Five findings from one session, all of the same family: a check,
a merge, or an environment that *looked* settled and was not. Two of them cost
real work. None was found by reading code; each was found by a measurement
disagreeing with a claim.

This appendix is the sibling of
[`APPENDIX_checks_that_cannot_fail_2026-11-20.md`](APPENDIX_checks_that_cannot_fail_2026-11-20.md),
which collects gates that reported success while evaluating nothing. That one is
about checks. This one is about the *topology* around them — where a branch
points, what a worktree is, which file a flag reads — because the same defect
shape lives there and nothing in the test suite can see it.

---

## 1. A pull request merged into a branch that no longer existed

**#340 was merged and its work never reached `main`.**

`fix/table1-custodian-sort` was merged into `main` in `ad3aec5` and left
standing as a ref. Three later pull requests — #334, #335 and #337 — had been
opened against it as their base, and so had #340. When #340 was squashed and
merged, the squash commit `f194e36` landed on `fix/table1-custodian-sort`.

```
$ git merge-base --is-ancestor f194e36 origin/main && echo YES || echo NO
NO
$ git branch -a --contains f194e36
  remotes/origin/fix/table1-custodian-sort
```

GitHub reported the pull request as merged, because it was. The commit exists,
the PR is closed, the branch was deleted. Nothing anywhere said "merged into
something that nothing merges."

### What was stranded

| stranded | recovered to `main` as |
|---|---|
| `tests/ci_unused_dependencies.R` (U1 gate) | restored, wired in `ci.yml` |
| `tests/test_wilson_implementations_agree.R` (W1–W3, rOpenSci G5.4a) | restored, wired in `ci.yml` |
| Wilson 1927 and Brown/Cai/DasGupta 2001 citations | `R/lib/wilson_interval.R` |
| Efron 1979, Efron & Tibshirani 1993, Field & Welsh 2007 | `build_f2_f3_uncertainty_denominators.R` |
| all five as BibTeX | `manuscript/references.bib` §4 |
| the methods paragraph citing them | `manuscript/federal_database_accuracy.qmd` |
| sixteen unused `library()` attachments cut | the sixteen files, individually |

### How it surfaced

Not by review. By writing documentation: a check of whether two files from #340
were present returned `ABSENT`, three hours after #340 had been reported merged.
The gate that would have caught it is the one that was stranded — `U1` fails on
`main` the moment it is restored, because the sixteen cuts it polices were
stranded with it.

### Why recovery was selective, not a cherry-pick

`git cherry-pick f194e36` onto current `main` would have reverted everything
merged in between — the squash was computed against the old base, so its tree
carries that base's version of 86 files, which is `-3189` lines against today's
`main`. Each piece was instead checked individually: a file whose only
difference from `main` was the stranded change was taken wholesale (12 of the
16 attachment cuts, all four citation files, both gates); a file that `main` had
since changed was edited by hand (`geocode_midwives.R`,
`make_trilliant_figures.R`, `scrape_healthgrades_midwives.R`,
`R/01-build-county-base.R`, all four touched by #342).

One cut was verified beyond the gate's word. `scrape_healthgrades_midwives.R`
attaches `humaniformat`, which the static scan calls unused — and the test that
exercises that file (`test_cycle31`) **skips on every runner**, so #340's green
CI never executed it. The attachment is genuinely unnecessary: the isochrones
name tools attach it themselves (`core_utils.R:76`,
`batch_npi_processing.R:52`) and otherwise namespace it
(`matching_utils.R:371` guards with `requireNamespace`). A green gate plus a
skipped test is not evidence; the dependency had to be read.

### What to do about it

- **Check a PR's base before trusting its merge.** `gh pr view <n> --json baseRefName`.
  A base that is not `main` is either deliberate stacking or a mistake, and the
  two look identical in the merge box.
- **Delete a base branch when it merges.** `ad3aec5` left the ref alive, which
  is what let four PRs keep pointing at it.
- Retargeting fixes it without rework: `gh pr edit <n> --base main`.

---

## 2. The same dead base made three pull requests look conflicted

#337, #334 and #335 all reported `CONFLICTING/DIRTY`. None of them conflicted
with `main`. They were being diffed against `fix/table1-custodian-sort`, which
`main` had moved a long way past.

```
$ gh pr edit 337 --base main
$ gh pr view 337 --json mergeable,mergeStateStatus
MERGEABLE/BLOCKED        # blocked only on checks, which had never been run
```

`git merge-tree --write-tree origin/main origin/<head>` is the cheap
independent check: it reports conflicts against whatever you name, so it
disagrees with the merge box exactly when the base is the problem.

A second-order effect: a push to a branch whose PR targets a dead base **does
not trigger the CI workflow**, because the workflow runs on pull requests
targeting `main`. #337 sat with one check (an external reviewer bot) and no CI
at all, looking merely slow rather than unwired. `gh pr update-branch` after
retargeting is what started the run.

---

## 3. A scratch worktree is neither environment the skip budget models

`tests/ci_skip_budget.R` splits the world in two — `full` (the person-level
freeze is present) and `lean` (a bare checkout, which is CI). Four rows do not
skip for data at all. `test_cycle11_spatial` and
`test_cycle14_coverage_surfaces` skip when `sf` is absent;
`test_cycle12_names_territories` and
`test_cycle31_healthgrades_insurance_parsing` skip without the `~/isochrones`
checkout. Those are properties of the *machine*, and the freeze says nothing
about them.

A worktree cut under `/tmp` has no `artifacts/`, so it is classified `lean` and
those four are expected to skip once each — while it still sees the developer's
installed `sf` and their `~/isochrones`, so they do not skip at all. All four
reported `STALE`.

They were reported as four stale budget entries. They were not stale; the
environment was misdescribed. **Lowering their `lean` count to match would have
reddened CI**, where the skip is real.

The fix is a `needs` column: a row names its own precondition, and that selects
the column instead of the global flag. No new column semantics — `full` already
means "the thing this row needs is here".

```
needs = pkg:<packages>      all must be installable
        iso:<paths>         under $ISOCHRONES_R (default ~/isochrones/R)
        path:<paths>        absolute or ~ paths
```

An unrecognised spec **fails** rather than falling through, because a row the
gate cannot answer for is a row whose count was never checked — and at
`full == lean == 0` the budget would otherwise report `PASS`, which is the very
defect it exists to prevent.

### Simulating an absent precondition

The spec restates the test's own guard, so the two can drift. Verify both
directions rather than assuming:

```sh
printf 'ISOCHRONES_R=/nonexistent/iso/R\n' > /tmp/noiso.Renviron
R_ENVIRON_USER=/tmp/noiso.Renviron Rscript tests/ci_skip_budget.R
# both iso rows switch to `lean` AND the tests actually skip: observed 1, expected 1
```

**`R_ENVIRON_USER` is load-bearing.** `~/.Renviron` sets `ISOCHRONES_R`, and R's
`.Renviron` processing **overrides the inherited shell variable**, so

```sh
ISOCHRONES_R=/nonexistent Rscript tests/ci_skip_budget.R   # does NOT simulate absence
```

silently keeps the real path. That produced one wrong measurement in this
session before it was noticed.

---

## 4. `.git` is a file in a worktree, and one root-detection idiom breaks on it

Thirty-one files locate the repository root with some form of:

```r
root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
```

In a worktree, `.git` is a **file**, not a directory, so `dir.exists()` is
`FALSE` on both arms and `root` stays at the working directory.

That is harmless for a gate run as `Rscript tests/foo.R` from the repository
root, where the working directory already *is* the root. It is not harmless
under `testthat::test_file()`, whose working directory is `tests/`:

```
$ cd <worktree> && Rscript -e 'testthat::test_file("tests/test_invariants_midwifery.R")'
ERROR 'test_invariants_midwifery.R:29:1' cannot open file './tests/helper-invariants.R'
[ FAIL 1 | WARN 1 | SKIP 0 | PASS 0 ]
```

In a real checkout the same file reports `PASS 49`. CI uses `actions/checkout`,
which creates a real `.git` directory, so **CI is unaffected** — this is a
worktree-only defect, and the reason a skip-budget row reads `STALE` there.

Two things worth noting rather than fixing blind:

- `file.exists(".git")` is true for both a directory and a file, and would fix
  all thirty-one. Not applied here: thirty-one files is its own change, and the
  idiom is correct in every context CI uses.
- The budget's non-vacuity guard catches a testthat run that produces **no**
  summary line. It does not catch one that produces `SKIP 0 | PASS 0` — a file
  that errored on load asserted nothing, and the budget reads it as "zero
  skips, as expected." That hole is real and is **not** closed.

---

## 5. Two debt entries claimed the same id, and the gate caught it

Merging `main` into #302 produced a `DEBT.md` with two `D13` headings: this
branch had filed the PECOS dedup-determinism bug as D13 on 2026-11-06, and
`main` had since filed the DAC multi-site ZIP5 bug as D13 on 2026-11-12.

```
FAIL B5: duplicated id(s): D13
```

Keeping both sides of that conflict is the *correct* resolution for the prose —
two unrelated bugs, neither a duplicate of the other — and the wrong one for
the label. Renumbered to D15. Review did not find this; `tests/ci_debt_check.R`
did, on the first run after the merge.

### The badge nobody checks

`ci_debt_check.R` validates ids, statuses and owners. It never compares the
README's count badge to `DEBT.md`. On `main` before this session the file held
11 closed and the badge claimed 10, and #302 existed partly because that same
badge had gone stale once before.

The count is now computed from the file (4 open, 12 closed) rather than carried
forward. **Nothing stops it drifting again.** A comparison of the badge against
`grep -c 'status:\*\* closed' DEBT.md` belongs in `ci_debt_check.R`; it is
deliberately not added here, because growing a gate inside a docs merge is how
a change stops being reviewable.

---

## The shape, stated once

Every item above is a claim that was true when written and was never re-checked
against the thing it described:

- a merge box that says "merged" without saying *into what*
- a conflict marker that describes a dead base rather than the code
- an environment flag that reads one file and names two worlds
- a root detector that asks `dir.exists` of something that is sometimes a file
- a badge that counts what a human counted once

The repository's existing answer to this is a gate per claim, and a saboteur per
gate to prove the gate can fail. Four of these five had no gate, because they
are properties of the *repository's topology* rather than of its data — and that
is the category this appendix exists to name.
