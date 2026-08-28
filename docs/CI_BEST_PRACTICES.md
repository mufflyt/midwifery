# CI Best Practices Checklist

A portable audit checklist for GitHub Actions CI across repos (midwifery,
isochrones, simulation, and others). Every item below is either a
well-established practice or a lesson pulled directly from a real incident —
where it's the latter, the incident is named so the rule doesn't read as
arbitrary.

How to use this: for each repo, go through the items and mark pass/fail/n-a.
Concrete "how to check" commands are given where possible so this can be
scripted, not just read.

---

## 1. Tier your checks by cost, and gate PRs with the cheap tier only

**Rule**: split CI into a fast, always-on tier (seconds, PR-gating) and a slow,
comprehensive tier (minutes-to-hours, nightly or on-demand). Never let the
slow tier be the *only* place a real correctness check lives if it's cheap
enough to run on every PR.

**How to check**: `grep -A3 "^on:" .github/workflows/*.yml` — does the
comprehensive suite trigger only on `schedule`? If so, list every check inside
it and ask: does any of these cost <5s and need no packages beyond what a
faster job already installs? If yes, it belongs in both places.

**Incident**: midwifery's `test_frozen_dependency.R` (a dependency-completeness
check, ~1s, needs only `dplyr`/`readr`/`jsonlite`) lived *only* in the nightly
job. Three separate PRs (2026-08-10, -08-15, -08-28) merged a script that
silently violated it, and each time the violation sat undetected on `main`
for up to 24 hours before the next scheduled run caught it. Duplicating the
check into the PR-gating workflow cost ~1 second of CI time and would have
caught all three at merge time.

---

## 2. Package/dependency discovery must follow `source()` chains AND grep for `pkg::fn()`, not just top-of-file `library()`

**Rule**: before adding a test/script to a CI job's install list, don't just
read its top-of-file `library()` calls. (a) Follow every `source()` /
`sys.source()` chain to every file it reaches, and check *those* files' needs
too. (b) Grep the whole reachable set for `[A-Za-z.]+::` namespaced calls —
these attach a package without ever calling `library()`, and are invisible to
a naive top-of-file scan.

**How to check**:
```bash
# for one file, plus everything it source()s
grep -ohE '\b[A-Za-z][A-Za-z0-9.]*::' file.R sourced_file1.R sourced_file2.R | sort -u
```

**Incident**: midwifery's L6-L10 CI-hardening fix (2026-08-28) needed three
separate rounds to get the install list right. Round 1 (grep for `library()`
only) found 7 packages and still failed with "no package called 'X'" for 2 of
5 gates. Round 2 traced the actual crash and found `openssl::sha256()` and
`jsonlite::read_json()` — both called with `::`, never `library()`'d, one of
them three `source()` hops deep in a shared helper (`R/lib/cache_vintage.R`).
Neither was caught until the check was *run for real* and its raw error read.

---

## 3. "Passes locally" proves nothing — verify in a genuinely fresh clone with `HOME` redirected

**Rule**: your local machine has every package you've ever installed and
whatever's sitting in `/tmp` or `~/`. Before trusting a test belongs in CI,
clone `HEAD` into a scratch directory, point `HOME` at an empty directory, and
run it there.

**How to check**:
```bash
rm -rf /tmp/fresh_clone_test && git clone --depth 1 file://$(pwd) /tmp/fresh_clone_test
cd /tmp/fresh_clone_test && HOME=/tmp/fresh_home_test Rscript path/to/test.R
```
A clean local `Rscript` run that skips this step proves nothing about CI.

**Incident**: midwifery's `ci.yml` header documents this exact lesson from
its own history — "cycle6 passed locally for exactly that reason and went red
here [CI]: a stale file in /tmp was still sitting" after a fresh-clone check
that redirected `HOME` but not `/tmp`. Check both.

---

## 4. Each job in a workflow file runs on an independent, fresh runner — nothing carries over

**Rule**: `apt-get install` or `install.packages()` done in one job is
invisible to every other job in the same workflow file, even ones defined
later in the same YAML. If two jobs both need a system library or an R
package, both need their own install step. Don't assume "the earlier job
already installed it."

**How to check**: for every `runs-on:` job, does it install everything it
`library()`s / `pkg::`s itself, without relying on a sibling job's steps?

**Incident**: midwifery's first `nightly.yml` fix (2026-08-28) added an R
package install step to the `Published numbers reproduce` job but not the
`sudo apt-get install libgdal-dev libproj-dev libgeos-dev libudunits2-dev`
step that `sf` needs to compile — because that step already existed in the
*separate* `r-suite` job earlier in the same file, and it was easy to assume
(wrongly) that it applied workflow-wide. Result: `sf` had no binary and failed
to compile from source — `Error: package still unavailable after install: sf`
— on the very run meant to confirm the fix.

---

## 5. A check that silently skips is indistinguishable from one that passed — make skips loud, countable, and classified

**Rule**: never let "the input was absent" and "the check ran and found no
problem" collapse into the same green outcome. Print an explicit SKIP with a
reason. Count skips separately from passes in a summary. Distinguish *expected*
skips (a genuinely optional/private input) from *unexpected* ones (a tracked
input the check needed and didn't get) — an unexpected skip should fail the
build, not pass it.

**How to check**: for every conditional early-return / skip branch in a test,
does it print a distinguishing message? Does the CI summary count skips
separately from passes? Would a reader scanning a green build notice if every
single check silently skipped?

**Incident**: midwifery's `tests/ci_law_coverage.R` exists specifically to
prevent this — its own header says "A law that is written but never evaluated
reports nothing and fails nothing. It is indistinguishable, in a green build,
from a law that passed." It classifies every check's outcome into `PASS`,
`EXPECTED_PRIVATE_SKIP`, or `FAIL`, and a `FAIL` occurs precisely when a
`public` (must-never-be-absent) check's input goes missing.

---

## 6. Explicitly classify each check's inputs as "must always be tracked" vs "legitimately absent sometimes"

**Rule**: a check that reads a gitignored/person-level/environment-specific
file will *always* be absent on a fresh CI checkout. If that's expected,
register it as such explicitly (not just via an ad hoc `if (file.exists())`)
so its absence is counted as a deliberate, reviewed exception — not silently
conflated with "everything's fine" or wrongly flagged as a hard failure.

**How to check**: does every check's registry/manifest entry state whether its
inputs are guaranteed-present ("public") or may-legitimately-be-absent
("private")? Does a `public` check that skips fail the build?

**Incident**: midwifery's L5 law needed a gitignored derived artifact
(`artifacts/maps/*.rds`) that can never exist on a fresh checkout, but was
registered `public` — meaning every single CI run failed it, permanently, by
construction, regardless of any real regression. Reclassifying it `private-ok`
in the registry (matching its true input class) fixed it in one line, once the
mismatch was actually noticed.

---

## 7. Path-filtered / conditional CI triggers should read from a live registry, not a hand-maintained path list

**Rule**: if you want an expensive check to run only when "relevant" files
change, don't hardcode a `paths:` filter list that has to be manually kept in
sync with wherever the real list of relevant files is declared. Compute
relevance from that declaration at run time instead.

**How to check**: does the workflow have a `paths:` filter, or a shell
conditional, whose file list duplicates something already declared elsewhere
(a registry, a manifest, a `REBUILD_ORDER`-style list)? If the underlying list
changes, does the filter update automatically, or does someone have to
remember to touch both?

**Incident**: midwifery's path-filtered `science-law-coverage` job reads
`tests/science_law_registry.tsv` at run time and diffs the PR's changed files
against its `gate`/`mutation` columns, rather than hardcoding a `paths:` list
— explicitly to avoid the same "prose mirrors data" drift the registry itself
was built to prevent (the registry's own header: *"THE MAPPING IS DATA, NOT
PROSE"*).

---

## 8. When a gating/filtering step can't determine applicability, fail open (run the check), never fail closed (skip it)

**Rule**: a relevance-detection step (path filters, diff-based conditionals,
etc.) will occasionally hit a case it can't resolve — no base ref, a
force-push, a shallow clone, `workflow_dispatch` with no diff context. Default
to *running* the expensive check in that case, not skipping it. A false
positive costs CI minutes; a false negative costs a real regression going
uncaught.

**How to check**: trace every exit path of the conditional logic. Does any of
them default to `run=false` / skip when the actual applicability is unknown
(not proven-negative)?

**Incident**: midwifery's relevance-detection script explicitly checks `git
cat-file -e "$BASE"` before diffing, and falls back to "run it anyway" — with
a printed reason — if the base ref isn't resolvable, rather than silently
skipping.

---

## 9. Comments that assert "this currently fails/passes" go stale — re-verify periodically, don't just trust the prose

**Rule**: a comment like "excluded because it fails in a fresh clone today"
is a *claim about a point in time*. Code changes; the claim doesn't
automatically update itself. Periodically re-run what the comment claims, and
correct or remove stale claims rather than propagating them forward.

**How to check**: grep for comments containing "today", "currently", "for
now", "as of [date]" near exclusion lists or skip conditions. Re-verify each.

**Incident**: midwifery's `ci.yml` explicitly excluded
`test_frozen_dependency.R` with the comment "fails in a fresh clone today."
That was true when written; a later fix (the T5 dependency-completeness bug
fix) made it false, and the stale comment kept the test excluded from
PR-gating CI for the following~ 3 weeks it took the next regression to surface,
until this audit re-checked the claim directly.

---

## 10. A completeness/meta-gate needs its own test — a checker that can't detect its own violation is decoration

**Rule**: if you write a gate whose entire purpose is "catch when someone
forgets X," write a second test that plants exactly that omission and asserts
the gate catches it. An enforcement mechanism that has never been proven to
fire is unverified, no matter how solid its logic looks on read-through.

**How to check**: for every completeness/consistency/coverage gate, is there
a sibling `test_*_detect.R`-style file that deliberately breaks the invariant
and checks the gate flags it?

**Incident**: this is already deeply embedded in midwifery's culture —
`test_frozen_dependency.R`'s own T9 is "NEGATIVE CONTROL: changing an input
makes the artifact stale," and the wider science-law registry requires every
law to have a `mutation` script that plants a defect and proves the gate kills
it (`Planted defects detected: 30/30` in a healthy run). Import this pattern
into any repo writing meta-gates.

---

## 11. Don't let a captured subprocess's real error get swallowed into a generic bucket

**Rule**: if a test harness runs sub-checks as subprocesses and parses their
captured output for specific markers (e.g. `[LAW] X EXERCISED`), make sure a
*crash* (missing package, unhandled exception) is distinguishable in the
summary from a deliberate, documented skip. Don't let both collapse into the
same "no subjects" bucket — a reader needs to know whether to fix a dependency
or investigate a genuine gap.

**How to check**: intentionally break a sub-check (delete a needed package,
introduce a syntax error) and confirm the harness's summary output makes that
failure mode identifiable, not indistinguishable from "this input was
legitimately absent."

**Incident**: midwifery's `ci_law_coverage.R` captures each gate script's
`stdout`+`stderr` via `system2(..., stdout = TRUE, stderr = TRUE)` and parses
it for `[LAW] X EXERCISED` / `SKIPPED` markers. A missing-package crash
matches neither regex, so it silently fell into "no subjects" — identical to
the legitimate-skip case — for two full days before being traced by hand.

---

## 12. Budget every expensive check, and print its elapsed time on every run — not just when it breaches

**Rule**: a check that stops finishing (hangs, or degrades quadratically) is
not a slow check, it's an *absent* check — but it still shows red the same
way a broken repo does, which reads as flakiness and gets muted or ignored.
Set a generous wall-clock budget per expensive step, and print the elapsed
time to the run summary unconditionally (pass or fail), so a slow drift is
visible in the trend long before it breaches.

**How to check**: does every step that could plausibly take minutes have an
explicit timeout distinct from the job-level default? Is elapsed time recorded
to the summary on every run, not just logged on failure?

**Incident**: midwifery's `nightly.yml` comment on this is explicit: a
`ci_science_nightly.R` step that ran ~5s for weeks silently became O(n²) after
an unrelated data-widening change (37 numeric columns added to a county
artifact) and crept past 15 minutes against the job's 20-minute timeout,
caught only by hand during a merge review. The fix pattern used throughout
this file: `BUDGET=<n>`, wrap the step in `start=$(date +%s)` /
`elapsed=$(...)`, echo elapsed unconditionally to `$GITHUB_STEP_SUMMARY`, and
`exit 1` (with an explanatory message) only if the budget is breached — after
the correctness check itself has already passed or failed on its own terms.

---

## 13. A job that's meant to gate merges has to be added to branch protection explicitly

**Rule**: GitHub does not infer "required" status from a workflow file. Adding
a new job (or renaming an existing one) has zero effect on what blocks a merge
until someone updates the repo's branch-protection `required_status_checks`
list to match. A job can run, pass, fail, and be completely decorative the
whole time.

**How to check**:
```bash
gh api repos/OWNER/REPO/branches/main/protection --jq '.required_status_checks.contexts'
```
Compare that list against every job name in `.github/workflows/*.yml` that
you intend to be blocking. Any mismatch — a job present in the workflow but
absent from this list — is silently non-blocking.

**Incident**: midwifery's 2026-08-28 CI-hardening session built a brand-new
`Science-law coverage (path-filtered)` job specifically to gate merges against
the class of regression that caused two Nightly failures that week. It ran
clean on its first real PR. `required_status_checks.contexts` still listed
only the three original jobs from before that session — the new job could
have failed on every subsequent PR and none of them would have been blocked.
Fixed via `gh api -X PATCH .../required_status_checks -F strict=true -f
'contexts[]=...'` (the scoped endpoint — it updates only the contexts list,
not the rest of branch protection, so `enforce_admins`, force-push rules, etc.
are untouched by the same call).

---

## 14. Pin the dependency *snapshot*, not just the package names

**Rule**: an install list like `install.packages(c("dplyr", "sf", ...))`
against a rolling mirror (`.../latest`) is not reproducible over time — CI can
go red tomorrow with zero commits, purely from an upstream release. Point at
a dated snapshot instead.

**How to check**: `grep -rn "RSPM\|packagemanager.posit.co" .github/workflows/*.yml`
— does any URL end in `/latest` rather than a fixed date (e.g.
`/2026-08-28`)? Same idea applies to any other rolling package index
(PyPI without a lockfile, `npm install` without a committed `package-lock.json`).

---

## 15. Cancel superseded runs; don't let redundant CI pile up

**Rule**: pushing several commits in quick succession (chasing a fix, as in a
live debugging session) queues one full CI run per push. Without cancellation,
all of them run to completion, burning minutes on results nobody will read
because a newer push already superseded them.

**How to check**: does the workflow file have a top-level `concurrency:`
block? If not:
```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

**Incident**: this exact session triggered roughly five overlapping CI/Nightly
runs on one branch while iterating on a fix (each new push obsoleting the
previous run's in-flight result). None of that was harmful, but all of it was
waste that `cancel-in-progress` would have reclaimed automatically.

---

## 16. Scope `GITHUB_TOKEN` to least privilege

**Rule**: without an explicit `permissions:` block, workflows get the
repository's default token permissions, which are broader than almost any
job needs. Declare `permissions: contents: read` at the workflow or job level
and widen only the specific job that genuinely needs more (e.g. one that
comments on a PR needs `pull-requests: write`).

**How to check**: `grep -n "^permissions:" .github/workflows/*.yml` — absent
entirely means the default (broad) token is in play everywhere. This matters
most for workflows that run on `pull_request` from forks, where a compromised
or malicious dependency pulled in during the run has that token's full scope
to work with.

---

## 17. Lint the workflow YAML itself

**Rule**: a malformed `if:` condition, a typo'd context expression, or a bad
indent doesn't error loudly — the step or job silently never runs, or runs
unconditionally when it shouldn't. `actionlint` (or `yamllint` plus a
GitHub-Actions-aware pass) catches this class of mistake before it reaches a
real run.

**How to check**: is there a pre-commit hook or CI step running `actionlint`
over `.github/workflows/`? If the only validation is an ad hoc `python3 -c
"import yaml; yaml.safe_load(...)"` run by hand before each push, that only
proves the YAML *parses* — it says nothing about whether a `steps.x.outputs.y`
reference actually resolves, or whether an `if:` expression is well-formed.

---

## 18. Give ad hoc debugging a `workflow_dispatch` escape hatch

**Rule**: investigating a CI-only failure (something that reproduces on the
runner but not locally) often means adding a temporary diagnostic step,
pushing, watching, then reverting the diagnostic once the real fix lands —
a throwaway commit cycle. A `workflow_dispatch` boolean input gating an
optional debug step avoids the commit-push-revert churn for the *next* one of
these.

```yaml
on:
  workflow_dispatch:
    inputs:
      debug:
        type: boolean
        default: false
steps:
  - name: DEBUG - stream verbose output
    if: ${{ inputs.debug }}
    run: ...
```

**Incident**: diagnosing why L8/L10's gates failed only in real CI (not
locally) required exactly the throwaway-commit pattern this item exists to
avoid: a debug step was added, committed, pushed, watched, and then removed
in a follow-up commit once the real cause (`openssl`/`jsonlite` missing from
the install list) was found.

---

## 19. Comment the incident, not just the mechanism — and hold new CI code to the same bar

**Rule**: `# retries on failure` explains *what*. `# retries because the RSPM
mirror 503'd for 40 minutes on 2026-06-02 and we lost a whole afternoon
assuming our code was broken` explains *why*, and gives the next person
(including a future you) enough to judge whether the situation still applies.
This is worth stating as a positive standard, not just a warning against decay
(see item 9) — it's what makes an incident-driven check auditable at all
instead of a black box someone's afraid to touch.

**How to check**: pick five `run:` steps at random. Does the surrounding
comment explain a real failure mode this step prevents, or does it only
restate the command? If a reader can't tell *why* the step exists from the
comment alone, it's mechanism-only.

**Incident**: this whole document exists because midwifery's `.github/workflows/*.yml`
already practices this well enough that a 2026-08-28 debugging session could
reconstruct exact incident dates, commit hashes, and root causes for gates
written weeks earlier — see items 1-12, every one of them sourced from a
comment or a log, not from memory.

---

## 20. Track flake rate as its own signal, separate from pass/fail

**Rule**: a check that occasionally goes red and passes on an unchanged rerun
is not "basically fine" — every flake spends down the trust that makes a red
build mean something. Left untracked, the usual endgame is someone adding
`continue-on-error: true` or a retry loop that papers over a real
intermittent bug. Track rerun-without-change events (even a simple log or
label) so a rising flake rate on one check is visible before it's muted.

**How to check**: is there any record of "this check failed, then passed on
rerun with no code change"? If the only artifact of a flake is someone
clicking "re-run failed jobs" and moving on, the signal is being thrown away.

---

## 21. `covr` (or equivalent line-coverage tooling) is a useful blind-spot finder, not a target

**Rule**: `covr::package_coverage()` (R) or an equivalent line-coverage tool
answers a narrower, cheaper question than this repo's own mutation-testing
discipline already asks: not "does the suite catch a real defect" (planted
defects, `X/Y detected`) but "does *any* test invoke this line at all." That's
a genuinely different blind spot — a function nothing calls, a branch nothing
exercises — and mutation testing can't find it either, because a mutation
harness only mutates code the suite already reaches. Worth adding as a cheap,
separate CI job; not worth gating merges on a coverage *percentage*, which is
trivially gameable (a test that calls a function and asserts nothing raises
coverage with zero verification) and would push against the stronger
discipline already in place here.

**How to check**: is there a coverage job at all? If yes, does the workflow
fail a PR for dropping below a numeric threshold — and if so, is that
threshold actually catching anything the mutation-testing job wouldn't have
caught anyway? A coverage regression on files the mutation suite already
exercises is redundant signal; a coverage regression on files *outside* any
mutation harness is the useful case.

**Recommendation for this repo specifically**: add `covr` as an
`if: always()`, non-blocking, informational job (mirroring the existing
`Network-dependent tests (informational)` / `Private-dependency tests
(informational)` pattern already in `nightly.yml`) that reports per-file
coverage to the run summary. Use it to find R/*.R files with literally zero
test invocation — a real gap the existing "No test file goes unrun" check
can't see, because that check verifies every *test* file runs, not that every
*source* file is reached by one. Do not make it a required/blocking check.

**Addendum, confirmed in `simulation` (2026-08-28)**: `covr::package_coverage()`
is also, incidentally, the single best available test of "does this code
correctly detect it is running outside a source checkout" — a property that
matters for any test suite with skip guards conditioned on repo-root
detection (see item 22). `covr` installs the package to a fully isolated
`temp_file("R_LIBS")` location with zero relationship to the checkout,
whereas `R CMD check` conventionally builds its check directory *adjacent* to
the source (a sibling of the checkout), so an upward filesystem walk from
inside the installed/check tree can accidentally stumble back into real
source files by proximity. Fourteen tests in `simulation` had exactly this
bug and R CMD check never caught it, on any of five platforms, because its
directory layout happened to mask it — only `covr`'s genuinely disconnected
install path exposed it. If a suite's skip guards matter for correctness
(not just tidiness), `covr` earns its CI minutes on this property alone,
independent of the coverage percentage it reports.

**Known covr limitation to design around**: `covr::package_coverage()`
reports a bare "Failure in `.../testthat.Rout.fail`" on the console/CI log
and then *deletes* that file on exit (`clean = TRUE` default) — so a CI log
alone gives zero detail about which test failed or why, only that something
did. To see the real content, reproduce locally with `clean = FALSE,
install_path = "/some/directory/you/control"` and read the preserved file
directly; do not trust the CI log's silence as evidence the failure is
non-diagnosable, and do not accept a chronically-failing `covr` job as
"just flaky" without doing this once.

---

## 22. Before reverting or reimplementing over a claimed missing upstream export, verify against the live default branch AND the actual runtime environment

**Rule**: "this function doesn't exist" is a claim with two independent
failure modes that both look identical from the outside: the export really
is missing, or the *check* was wrong — a stale local checkout, a commit that
predates the real merge, or an environment that silently can't see where the
package is actually installed. Before reverting good work or reimplementing
something that already exists upstream, verify against (a) the upstream
repo's actual current default-branch tip via its API, not a local clone that
might be behind, and (b) the *same* environment the claim was originally
tested in — not a `--vanilla`/minimal invocation that skips startup files a
normal run relies on.

**How to check**: for any "X doesn't exist upstream" claim attached to a
revert, diff, or bug report: `gh api repos/OWNER/REPO/commits/main --jq .sha`
and compare against whatever commit the original claim actually checked
(`git merge-base --is-ancestor <claimed> <live-main>` — if it's not an
ancestor, the claim checked something already superseded). Separately,
re-run `exists("the_function")` in the *exact* invocation style production
code uses (same `Rscript` flags, same shell profile), not a fresh minimal
session — a package installed via a personal `R_LIBS_USER` in `~/.Renviron`
is invisible to `Rscript --vanilla` even though it's genuinely installed and
genuinely on the machine.

**Incident**: private_equity's `assign_blinded_slots()` delegation to a
newly-merged mysterycall export was reverted by another session, citing "not
in mysterycall's source at af004a1, not in its NAMESPACE" and "5 failures, 7
errors" in the test suite. Direct re-verification found: `af004a1` was 14
commits *behind* the actual merge commit on mysterycall's live `main` (`gh
api repos/mufflyt/mysterycall/commits/main` returned the merge commit as
current HEAD, with the file present in the tree); the installed package
genuinely had the export (`exists(...)` true under a normal `Rscript`
invocation) but returned false under `Rscript --vanilla`, because `--vanilla`
skips `~/.Renviron`, which is what points `.libPaths()` at the library the
package actually lives in; and re-running the exact cited test file scored
101/101, not 5 failed/7 errored. The revert was made in good faith and
following a defensible "verify before trusting a delegation" instinct — it
was simply checking the wrong two things (an old commit, a non-representative
environment) and reverting real, working code on that basis.

---

## 23. An instantly-failing, uniform run across many consecutive pushes is more likely a billing/quota block than a code regression

**Rule**: a real test failure has *some* variance — different runs fail at
different steps, take measurably different time, or fail for different
stated reasons. A wall of runs that all fail in the same few seconds,
regardless of what the commit actually changed, is a strong signal the job
never started for real — check the run's own job-level annotation before
spending any time on the diff.

**How to check**: `gh run view <run-id>` and look at the `ANNOTATIONS`
section, not just the pass/fail summary — a billing block surfaces there as
plain text ("recent account payments have failed or your spending limit
needs to be increased"), distinct from any test output. If several
consecutive runs all failed in under ~10 seconds regardless of what changed,
suspect this before suspecting the code.

**Incident**: private_equity had roughly fifteen consecutive `gates`/`nightly`
runs fail in 3-5 seconds each across 2026-08-24/25, spanning several
unrelated commits with genuinely different content. `gh run view` on the most
recent one showed the real cause in its annotations: a GitHub Actions billing
failure on the account, unrelated to repo visibility (confirmed separately —
making the repo public did not clear it) and unrelated to every one of those
commits' actual content. Every run had the identical annotation; none of them
had actually executed a single test.

---

## 24. Scheduled (cron) triggers on low-activity repos can be delayed by hours or skipped entirely — verify actual firing time as its own signal, separate from whether the job passes

**Rule**: `on: schedule` is a request, not a guarantee — GitHub's own docs
state scheduled workflows may be delayed during periods of high load, and in
practice repos with infrequent activity get deprioritized further. A
green run history says nothing about whether the schedule is actually firing
on the cadence you configured; check the two separately.

**How to check**: `gh run list --workflow=X.yml --json createdAt,event` and
compare each `"event": "schedule"` run's `createdAt` against the configured
cron expression — is the gap between consecutive scheduled firings close to
24h (or whatever the interval is), or are there multi-day gaps with no
scheduled run at all? Round UTC times (`0 0/6/9/12 * * *`) queue behind the
largest number of other repos' identically-timed cron jobs; an off-round
hour and minute (e.g. `23 6 * * *`) is GitHub's own stated mitigation.

**Incident**: private_equity's `nightly.yml`, configured for `0 9 * * *`
(09:00 UTC), had exactly one real `schedule`-triggered run in its history,
landing at 19:18 UTC — about 10 hours late — with no second scheduled run
appearing the following day despite the trigger time having long passed.
Every job that *did* run (that one, plus several `workflow_dispatch` manual
triggers) passed cleanly; the unreliability was entirely in whether GitHub
attempted to run the job at all, not in the job's own correctness. Rescheduled
to `23 6 * * *` as a mitigation, explicitly flagged as unverified until
observed to actually land closer to on-time over subsequent days.

---

## 25. Pinning a floating GitHub-remote dependency in a commit-blocking job is a real tradeoff, not a strictly-better default — decide it deliberately, per repo

**Rule**: item 14 argues for pinning package snapshots, and the argument is
sound: a job that blocks every commit and PR re-installing a dependency from
its upstream `main` on every run means that job's stability is hostage to
however many other people are pushing to that dependency's default branch at
any given instant, with zero relationship to whether *this* repo's own code
is correct. But pinning has a real, non-hypothetical cost too: every
legitimate upstream improvement now requires a deliberate bump commit instead
of arriving automatically, and a maintainer who wants "always test against
the true current state of my dependencies" has a real reason to prefer
floating despite the risk. Don't present pinning as costless; let whoever
owns the repo make the call with both sides stated.

**How to check**: for any commit-blocking job installing a package via
`github::owner/repo` (no `@ref`) or an unpinned git remote, ask the repo
owner directly which failure mode they'd rather have: occasional
unrelated-commit breakage from upstream drift (floating), or dependency
updates requiring a manual bump to ever reach this repo (pinned). Implement
whichever they choose, but implement the *choice*, not a default.

**Incident**: private_equity's `gates.yml` was floating `github::mufflyt/
mysterycall` and `github::mufflyt/researchpaths` with no pin, on a job that
blocks every commit. Proposed and implemented pinning both to their current,
verified-working commits (with the reasoning offered here), verified the
`owner/repo@sha` syntax actually resolves and installs correctly (confirmed
via `packageDescription()$GithubSHA1` matching exactly), and confirmed the
pinned job passed in real CI. The repo owner reviewed it and asked for a full
revert — "I was wrong and I want the floating main" — a deliberate,
informed decision to accept the drift risk in exchange for always testing
against the true current dependency state. Reverted cleanly via `git revert`
or a diff back to the pre-pin state. Both configurations are defensible; the
mistake would have been picking one silently instead of surfacing the
tradeoff and letting it be decided.

---

## 26. A skip guard that detects a missing precondition must skip — never substitute a guess and proceed

**Rule**: a helper that resolves some environment-dependent value (repo root,
config path, data location) and correctly detects "not found" has done the
hard part. The failure mode that erases that work is falling back to a
*guessed* value (`".."`, a hardcoded default, `getwd()`) and continuing,
instead of calling `skip()`/failing loudly. A guess-and-continue fallback
converts a clean, diagnosable "precondition not met" into a confusing
downstream assertion failure that reads like a real defect in the code being
tested, not like an absent environment.

**How to check**: grep for a root/path detector call immediately followed by
an `if (length(x) == 0) x <- <fallback>`-shaped guess, rather than a `skip()`
or `stop()`:
```bash
grep -rn -B1 -A2 "if.*length.*== *0" tests/ | grep -B1 -A2 '<- "\.\."' 
```
For every such site, ask: when the detector legitimately returns "not found,"
does execution stop (skip/fail) or does it substitute a guess and keep going?

**Incident**: `simulation`'s `coverage / lint / docs` nightly job failed on
every single run for weeks (10+ consecutive nights, unrelated commits).
Fourteen test files each defined a local `.repo_path()` helper that correctly
called the existing `.source_tree_root()` detector (which already had the
right Meta/-directory discriminator for "installed package vs. source
checkout") — but on an empty result, each one fell back to a guessed `".."`
instead of skipping, exactly the bug a comment in the repo's own
`helper-setup.R` already described and had only partially fixed. `R CMD
check`'s conventional directory layout happened to leave `".."` resolvable
to something adjacent to the real checkout, so the bug never surfaced there
or in a plain `testthat::test_dir()` run — only `covr`'s genuinely isolated
install path exposed it (see item 21's addendum). Fix: one shared,
skip-safe helper in a `helper-*.R` file (loaded before every `test-*.R`
file regardless of alphabetical order — the actual reason fourteen separate,
buggy copies existed), plus a regression test asserting no test file
redefines it locally.

---

## 27. A workflow's own green status doesn't prove the external platform it targets is actually provisioned

**Rule**: a deploy/publish job can build, test, and package everything
correctly and still fail at the final step because the *target* — a Pages
site, a registry, a database, an external service — was never actually set
up. The workflow file being well-formed and every prior step succeeding says
nothing about whether the destination exists. Verify the target platform
directly, independent of the workflow, and add a preflight check inside the
job that fails fast with an actionable message if it isn't provisioned.

**How to check**: for every deploy/publish step, identify what external
platform it targets and check it directly — e.g. `gh api repos/OWNER/REPO/pages`
for GitHub Pages, the registry's own API for a package publish target. Does
the deploy job have an explicit precondition step verifying the target
exists *before* calling the actual deploy action?

**Incident**: `simulation`'s `pkgdown` workflow's `deploy` job called
`actions/deploy-pages@v4`, which failed with a bare `HttpError: Not Found`
and no further explanation — because GitHub Pages had never been enabled for
the repository at all (`gh api repos/OWNER/REPO/pages` returned a plain 404).
The build and leak-guard steps both succeeded every time, so the workflow
*looked* healthy right up until the last step, and because `deploy` only
runs on a `push` to `main` (never on a PR, by design — see the workflow's own
"BUILD ON PR, DEPLOY ONLY FROM main" comment), the gap wasn't caught by any
PR-gating check either. Fixed by enabling Pages (`gh api .../pages -X POST -f
build_type=workflow`) and adding a precondition step to the `deploy` job that
checks the Pages API first and fails with the exact fix command if it's ever
disabled again.

---

## 28. A permanently-expected, by-design failure must not retrigger an alerting mechanism on every run

**Rule**: some CI gates are *supposed* to stay red for an extended, known
period (blocked on external data, an unresolved scientific parameter, a
pending upstream fix) — and that's a legitimate design (see the general
principle in item 6: classify inputs/conditions explicitly rather than
conflating them). But an alerting mechanism layered on top (a GitHub issue
comment, a Slack ping, a paging rule) that fires on *every* run because that
gate is part of its trigger condition turns a deliberate, accepted signal
into daily noise — and trains everyone to stop reading it, which is exactly
when a genuinely new, actionable failure gets missed inside the noise.
Separate "known, permanently-expected redness" from "something changed and
needs attention" at the alerting layer, not just at the blocking-gate layer.

**How to check**: for every alert/issue-comment/notification step, list its
*complete* trigger condition and compare it against what it actually
displays. Does a condition that's true on every run (a permanently-red gate)
appear in the trigger but not in the summary/body? If so, a "nothing new
happened" night still produces an alert.

**Incident**: `simulation`'s nightly workflow's "open or update the tracking
issue" step included a permanently-red job (`scientific-invariants` — a
scientific-readiness gate documented as red by design, blocked on real
longitudinal claims data not yet available) in its `if:` trigger condition,
but that job was *not* one of the rows in the issue body/table it posts. On
nights where nothing else failed, the bot still posted a new comment reading
"**Failing:** " (blank) to a single growing tracking issue — 17 comments over
11 days, several with an empty failing-list, on an issue that's been open
since before the observation window. Fix: exclude the permanently-expected
gate from the alerting trigger (its redness is already visible in the run's
own job list and step summary, which is the appropriate place for a
by-design daily reminder) while keeping it in the blocking-gate check that
makes the *workflow run itself* red — the alert should fire only for the
gates whose failure is actually unexpected.

---

## 29. A self-hosted/persistent runner inverts item 4's "nothing carries over" assumption — audit for state that outlives a job

**Rule**: item 4 is correct for GitHub-hosted runners, which are destroyed
after every job. A self-hosted runner that reuses the same machine (and,
critically, the same checkout directory) across jobs makes the *opposite*
assumption dangerous: anything not actively cleaned WILL persist, and a
package manager, lockfile, or installed artifact that a fresh-runner world
never has to reconcile against its own prior state can hit code paths that
are simply untested upstream. Before trusting self-hosted-runner advice
copied from ephemeral-runner experience, ask "if this exact job ran twice in
a row on the same machine, what would be different the second time?"

**How to check**: for every install/cache/lockfile step on a self-hosted
runner, trace what it writes outside the job's own checkout (a package
manager's own library, a tool's private dependency cache, a lockfile the
next checkout won't `git clean`) and whether a second run would find that
state already present.

**Incident**: isochrones' self-hosted-runner rollout (2026-08-24 through
-08-28) hit five distinct instances of exactly this, each invisible on the
project's prior GitHub-hosted history: (a) `/tmp/Rtmp*` session directories
from R processes killed mid-job accumulated to 75GB and filled the disk;
(b) `setup-r-dependencies@v2`'s default `pak-version: stable` silently
re-fetched a `pak` build targeting a different R patch version than the one
actually installed, breaking `pak`'s own private `cli` library
("Cannot load cli from the private library") across every workflow using
it; (c) a previous job's `.github/pkg.lock` — untracked, so never removed by
`actions/checkout`'s default clean — survived into the next job's reused
checkout and fed `pak`'s solver a plan computed against stale content; (d)
installing a package's own source (`local::.`) hit a reproducible internal
pkgdepends error ("Cannot select new package installation task") specific
to the package already being present from a prior run, a fresh-install-only
code path ephemeral runners never exercise; (e) four concurrent runner
agents shared one machine's `apt`/`dpkg` lock and collided on it. All five
were fixed (see the workflow files' own commit history), but each cost real
debugging time precisely because the failure mode doesn't exist in the
mental model most GitHub Actions advice, including item 4 above, is written
against.

---

## 30. An unrelated OS-level scheduled task can silently steal a resource your CI needs — rule out a background interloper before debugging your own tooling

**Rule**: on a long-lived (non-ephemeral) machine, cron jobs, systemd timers,
and unattended-upgrade mechanisms run independently of anything CI-related
and can hold a system-level lock or resource your job needs. A failure that
*looks* like a bug in code you just wrote — because the symptom is in your
own recently-touched wrapper or script — can actually be a completely
unrelated background process that happened to be running at the same time.

**How to check**: when a resource-contention error (a lock file, a busy
port, a "device or resource busy") appears on a persistent machine, `ps aux`
for anything unrelated holding it *before* assuming the bug is in the CI
code itself. `systemctl list-timers` surfaces scheduled culprits directly.

**Incident**: isochrones' self-hosted runner hit `apt-get`/`dpkg` lock
errors that looked exactly like a concurrency bug in a same-day fix (four
runner agents racing on the shared apt lock, item 29(e) above) — and a
`flock`-based wrapper built to fix *that* still failed identically. The
actual holder, found via `ps aux`, was `apt.systemd.daily` — Ubuntu's stock
daily update timer — which had been stuck holding the lock for **11+
hours**, entirely unrelated to any CI activity. Killing the stuck process
and permanently disabling `apt-daily.timer`, `apt-daily-upgrade.timer`, and
`unattended-upgrades.service` (none of which belong on a CI box) resolved
it; the earlier `flock` wrapper fix, while independently correct, had not
been the actual cause of that specific outage.

---

## 31. Before an elaborate "unreachable"/"hung" theory, re-verify the address itself hasn't changed

**Rule**: infrastructure that can restart (a stopped-and-started VM, a
container rescheduled onto new networking) commonly gets a new address on
restart. A connection failure to a server that was reachable minutes ago is
often nothing more exotic than retrying a now-stale address — check this
before reaching for a deeper theory (resource exhaustion, a networking bug,
a security-group regression).

**How to check**: for any "was reachable, now isn't" investigation on
restartable infrastructure, confirm the current address/endpoint
independently (`aws ec2 describe-instances --query
'...PublicIpAddress'`, a DNS lookup, a status API) before spending time on
a more elaborate hypothesis.

**Incident**: while load-testing isochrones' self-hosted runner, SSH access
appeared to fail under heavy concurrent CI load, and the investigation spent
real time on a connection-tracking-exhaustion theory (plausible given
observed multi-million-packet traffic volumes). The actual cause: the EC2
instance's idle-stop timer had fired and a webhook had since restarted it,
assigning a **new public IP** — every "unreachable" SSH attempt in between
was to the old address. `aws ec2 describe-instances` confirmed the new IP
in one call; the box itself was healthy the entire time (confirmed
separately once the correct address was used).

---

## 32. A newly-built "fast path" variant of an existing check needs to be run for real before it's trusted, regardless of how sound its design looks on read-through

**Rule**: generalizes item 10 (meta-gates need their own proving test) and
item 9 (stale claims decay) to a broader case: *any* new CI code path —
not just completeness gates — is unverified until it has actually executed
once, successfully, in the environment it will really run in. A carefully
reasoned design is not evidence it works; only a real, observed pass is.

**How to check**: for every CI path added or meaningfully changed, has it
been triggered for real (not just read) at least once since the change? A
path gated behind a rare trigger condition (a specific event type, a rare
file-change pattern) is the highest-risk case, precisely because it's the
easiest to leave unexercised for a long time.

**Incident**: isochrones' `pkgdown.yaml` grew a slimmed "PR-time roxygen
check only" path on 2026-08-24 to avoid running the full, expensive site
build on every PR. It sat unexercised — no PR or `workflow_dispatch` run
ever actually hit it — until 2026-08-28's CI-hardening session dispatched
it directly, four days after being merged. Its first real run failed
immediately: `roxygen2::roxygenise()` calls `load_all()`, which sources the
project's `01-setup.R`, which has an unconditional hard `stop()` if a
specific external drive isn't mounted — true on every CI runner, hosted or
self-hosted, meaning this path could never have succeeded from the day it
was written. The design (skip the expensive build, keep the doc-comment
check) was sound; the fact that it had never once actually run was the gap.

---

## 33. An identical failure signature surviving a targeted fix is evidence against the theory, not a reason to reinforce it

**Rule**: when a fix targets a specific hypothesized cause and the retest
produces the *exact same* failure (same message, same stack trace, same
step) rather than a different one, the natural instinct is "the fix didn't
fully apply, try harder." The better-supported read is the opposite: an
unchanged failure signature after a real, verified-applied fix means the
theory of causation was wrong, and a different cause should be sought — not
that the same fix needs reinforcing.

**How to check**: after any targeted fix, diff the failure signature
before and after, not just pass/fail. "Still red" and "red in the identical
place with the identical message" are different signals; only the latter
is evidence the theory itself needs revisiting.

**Incident**: isochrones' `pkgdown` full-build job hit a `pak`/`pkgdepends`
internal solver error ("Cannot select new package installation task").
First theory: a stale `.github/pkg.lock` left by a prior run on the
persistent self-hosted runner — cleared it, reran, identical error. Second
theory: the local package was already installed from an earlier bulk
install, confusing an install-vs-upgrade code path — removed it, reran,
identical error again, character-for-character. Only the third theory
(`local::.`'s install-in-place path itself hitting an untested edge case,
independent of any persisted state) actually changed the outcome once
applied — dropping `local::.` in favor of the action's own default
dependency-only resolution (`deps::.`) fixed it. The first two "fixes" were
each individually reasonable and each correctly ruled *out* by the
unchanged failure signature, not confirmed as incomplete.

---

## 34. Before writing a test against a file, `git ls-files` it — "exists on my disk" and "exists after a fresh clone" are different questions

**Rule**: sharpens items 3 and 6 into a concrete pre-write step, aimed at
the specific moment a *new* test is authored, not just at auditing
inherited ones. A file sitting on the machine you're developing on (your
own checkout, a persistent CI runner's reused work directory) proves
nothing about whether it's actually part of the committed repository. Check
`git ls-files <path>` — not `file.exists()` — before designing any
regression test around a data file's presence or content.

**How to check**: `git ls-files <path>` returns nothing → the file is
either untracked or gitignored, and any test reading it needs the item 6
PRIVATE-OK treatment (a legitimate, expected skip), never the PUBLIC
treatment (an unexpected skip fails the build).

**Incident**: isochrones' `test-data-regression-daily-guard.R` was written
(2026-08-27) and initially passed cleanly, including on the self-hosted
runner, against `data/abog_pipeline/canonical_abog_npi_LATEST.rds` and
similar derived files. A same-project CI Best Practices audit the following
day ran `git ls-files` against every path the suite read and found three of
six were never actually committed — `*.rds` and `*.csv` are blanket-
gitignored repo-wide by deliberate policy, narrow allowlist only — meaning
the suite had been "passing" purely off stale leftover files on the
persistent runner and the author's own machine (item 3's exact failure
mode, but for tests written *that same week*, not inherited legacy ones).
Fixed by reclassifying: two tests rewritten to pin the files' committed
metadata sidecars instead of the gitignored data itself; one test
reclassified explicitly PRIVATE-OK (runs deeper checks when the file
happens to be present, skips cleanly when it isn't); two tests replaced
outright with checks against genuinely tracked files. `git ls-files` before
writing, not `file.exists()` after failing, would have caught this at
authoring time.

---

## 35. In a multi-agent or multi-contributor session, check very recent commits before doing full root-cause work — someone else may have already fixed it

**Rule**: when more than one person or agent can push to the same branch
concurrently, a failure under investigation may already be resolved by a
commit that landed while the investigation was in progress. This isn't
covered by any single-investigator debugging discipline (including items
1-28 above, which all implicitly assume one thread of work at a time) —
it's a distinct check specific to concurrent contribution.

**How to check**: `git log --oneline -10 -- <path>` on the specific file or
area under investigation before starting deep root-cause work, especially
if `main` has moved since the investigation began. If a recent commit's
message plausibly targets the same symptom, verify against it before
re-deriving the same fix independently.

**Incident**: an isochrones CI-hardening session was mid-investigation of a
`test-s3-sync-atomic-staging.R` failure in the `Step 8 Incident Regression`
job when a re-check of the check-run status showed it passing — a
*separate*, concurrently-running Claude Code session (working in a
different terminal window on the same repo, confirmed via a screenshot
showing its own "Root cause found and fixed" summary) had independently
diagnosed and pushed a fix for the identical failure minutes earlier. No
duplicate work was done in that instance only because the check happened to
land before the independent re-derivation was complete — a `git log` check
at the *start* of the investigation would have surfaced the same
information without the timing dependency.

---

## 36. Top-level side-effect code in an R package's `R/` directory breaks any tool that sources the package, not just the pipeline run

**Rule**: `roxygen2::roxygenise()`, `devtools::load_all()`, `R CMD check`, and
most lint/doc tooling all work by *sourcing every file in `R/`* — not just
parsing it. Any top-level code (outside a function body) in one of those
files — a `readRDS()`, an API call, a `stop()` guarding a real pipeline input
— executes as a side effect of a documentation or syntax check that has
nothing to do with running the pipeline. A file written to be dual-purpose
("callable library of functions" *and* "runnable top-to-bottom as a numbered
pipeline stage") will pass in the actual pipeline (where its real inputs
exist) and fail every doc/lint check that merely loads the package (where
they don't) — and it will keep doing this for every *new* file written the
same way, even after the first instance of the bug is fixed elsewhere.

**How to check**: for any R package repo, grep every `R/*.R` file for
top-level (unindented, outside any `function(...) {`) calls to real I/O —
`readRDS`, `read.csv`/`read_csv`, `stop()` gated on `file.exists()`, an API
call:
```bash
awk '/^[a-zA-Z_.][a-zA-Z0-9_.]* *(<-|=)/ || /^(stop|if|cat|readRDS|read\.csv|read_csv)\(/' R/*.R
```
(crude — the real signal is "unindented code outside a function definition").
For each hit, ask: would `roxygen2::roxygenise()` or `devtools::load_all()`
execute this line on a fresh checkout with no data present?

**Incident**: `mufflyt/isochrones`' PR-gating `pkgdown.yaml` workflow
("Roxygenise (PR-time doc/syntax check only, no site build)" step) failed
repeatedly on 2026-08-28 (e.g. run `33181573109`, PR-triggered) with `Error
in load_all(): Failed to load 'R/08-area-weighted-overlap.R' ... ERROR:
Isochrone file not found: .../data/derived/provider_isochrones.rds`. The
file's top-level code (line 99: `INPUT_ISOCHRONES <- here(config$...)`;
lines 612-613: `if (!file.exists(INPUT_ISOCHRONES)) stop(...)`; line 825:
`isochrones <- load_isochrones(INPUT_ISOCHRONES)`) runs unconditionally when
the file is sourced, and the gitignored data file it requires is absent on a
fresh CI checkout by design. The repo's own workflow comments show the
authors already hit and partially fixed this *exact* class of bug once
before — `R/01-setup.R` is guarded by an `ISOCHRONES_SKIP_VOLUME_CHECK` env
var specifically because "`roxygen2::roxygenise() -> load_all()` sources
R/01-setup.R just to resolve doc comments — it never touches the database" —
but that guard covers only the one file it was written for.
`R/08-area-weighted-overlap.R` has no equivalent guard and fails the same
way, confirming the fix needs to be systemic (every `R/` file audited and
guarded, or top-level pipeline logic moved out of `R/` entirely into a
`scripts/`-style directory that isn't part of the loaded package) rather than
fixed file-by-file as each one is discovered failing.

---

## 37. A narrow, discriminating auto-retry for infrastructure setup hangs is safe; a generic retry-until-green is not

**Rule**: a third-party setup action (`r-lib/actions/setup-r` or similar)
hanging until its timeout kills the job is a real, recurring GitHub Actions
failure mode — and it's genuinely safe to auto-retry, *if* the retry logic
proves the failure happened before any real work started. A blanket
"retry on any failure" auto-rerun would mask genuine breakage (an extreme
version of item 20's flake-tracking concern). The safe version has three
specific properties: (1) only retries on `conclusion == cancelled`, never
`failure` — a real check result is never touched; (2) inspects every
non-succeeded job's step list and only retries if *every one* died inside a
named setup step (checkout/setup-r/setup-pandoc/system-deps), never one that
reached test/build/check; (3) retries the first attempt only — a second hang
is treated as a signal, not papered over.

**How to check**: does the repo have any workflow triggered on
`workflow_run` with `types: [completed]` targeting the main CI workflows? If
so, does its retry condition check *where* the job died (setup vs. real
work), or only *that* it failed?

**Incident**: `mufflyt/mysterycall`'s `auto-rerun-setup-hangs.yaml` exists
because — per its own header comment — `r-lib/actions/setup-r` hung five
times in a single day across four different branches, each requiring a human
to notice and manually re-run. The workflow has fired its full discriminator
logic 6 times since (runs `32766383130`, `32448758892`, `32371216555`,
`32371213202`, `32370214370`, `32370213411`); in every observed case it
correctly declined to auto-rerun (either "nothing unsuccessful" or "at least
one job got past setup, so the cancellation may have interrupted a genuine
failure") — proving the discriminator doesn't false-positive on real
failures, even though no genuine setup-hang has recurred in this window to
prove the positive path fires too.

---

## 38. A fail-open guard's precondition check must prove the SAME thing the guarded command needs — ref-resolvability is not ancestor-reachability

**Rule**: item 8 says a relevance/applicability check should fail open when
it can't determine applicability. But "fail open" only works if the
*precondition check* actually detects every way the guarded command can
fail. `git rev-parse --verify --quiet "$base"` proves `$base` resolves to
*some* git object — it does **not** prove `$base` and `HEAD` share a common
ancestor. `git diff --name-only "$base"...HEAD` (three-dot, symmetric-difference
form) needs exactly that common ancestor, and throws `fatal: Invalid
symmetric difference expression` — a hard, uncaught error under `bash -e` —
when there isn't one. A ref can resolve cleanly and still blow up the next
line.

**How to check**: for any script gating on `git diff "$A"..."$B"` (three-dot)
with a preceding existence check, does that check use `git merge-base "$A"
"$B"` (proves a common ancestor exists) or only `git rev-parse --verify`
(proves the ref merely exists)? The latter is not sufficient after any
history-rewriting event (force-push, rebase, squash-merge) that orphans the
"before" SHA from the new HEAD's ancestry.

**Incident**: `mufflyt/cliff`'s `ci.yml` `docs_touched` job (the render-gate
relevance check — conceptually the same pattern as this checklist's own item
7) has an explicit fail-open branch for exactly this class of problem: `if !
git rev-parse --verify --quiet "$base"; then echo "cannot resolve base;
rendering to be safe"; exit 0; fi`. On run `32778469469`
(2026-08-24T21:15:03Z, part of a ~3-second cluster of pushes with distinct
SHAs — `49443f5a`, `9153b7d6`, consistent with a rapid rewrite/force-push
sequence), `base` was `github.event.before =
ed84d2ec3b64234dcd341617717e41cfd4115e21`, which passed `git rev-parse
--verify` (the object existed, `fetch-depth: 0` so full history was present)
but had no common ancestor with the new `HEAD`. The subsequent `git diff
--name-only "$base"...HEAD` threw `fatal: Invalid symmetric difference
expression ed84d2ec...HEAD`, exit code 128, uncaught by `bash -e` — the job
failed hard instead of taking the fail-open path its own author had already
written for "this exact category of problem," because the existence check
and the ancestry the diff command actually needed weren't the same check.

---

## 39. A public, tokenless cross-repo verification harness must verify read access to its actual target before running, and refuse loudly if the target is unreadable

**Rule**: a "verifier repo" architecture — a separate, public CI harness that
validates a *different* "production" repo by checking it out via
`PRODUCTION_REPO`/`PRODUCTION_REF` inputs rather than testing its own
contents — has a failure mode unique to the split: if the production repo is
private and the harness deliberately holds no token (so its results are
publicly auditable without trusting a secret), it will get an HTTP 404
trying to read it. The harness must detect this explicitly and fail with a
message naming exactly what's readable and what isn't — not silently skip
(which would look like "nothing to verify, fine") and not attempt a degraded
verification against something it can partially see.

**How to check**: for any workflow that checks out a repo named by a
variable/input rather than `github.repository` itself, is there an explicit
preflight step confirming that repo+ref is actually readable in the current
auth context, before any real work starts? Does its failure message state
which specific repos are public vs. private, so the fix is obvious from the
error alone?

**Incident**: `mufflyt/isochrones-ci` ("Public CI and scientific-validation
harness for the isochrones pipeline. A verifier, not a second
implementation.") defaults its scheduled `nightly.yml` to `PRODUCTION_REPO:
mufflyt/mufflyaccess` (public) — every nightly run succeeds because that
target is genuinely readable. Its `manual.yml` allows an operator to point
the same harness at a different repo/ref via `workflow_dispatch`. On
2026-08-18 (run `32094339292`), someone dispatched it against
`mufflyt/isochrones@fix/band-monotonicity-dual-tolerance` — but
`mufflyt/isochrones` is private. The harness's guard step failed exactly as
designed: `##[error]mufflyt/isochrones returned HTTP 404. This harness is
public and holds no token, so it cannot test a private repository.
mufflyt/isochrones is private; mufflyt/mufflyaccess is public.` This is not a
bug — it's the correct, loud rejection of operator error (wrong target), and
it's exactly the kind of check that prevents a much worse outcome: a harness
that silently reports "PASS" while never having actually read the code it
claims to have verified.

---

## 40. A test matrix across OS runners can fail on graphics-device/system-library availability alone — same R version, same code, different platform capability

**Rule**: `strategy: matrix:` builds across `ubuntu-latest`/`macos-latest`/etc.
exist specifically to catch platform-dependent behavior, and graphics-device
output (EPS/PDF/PS export) is a common source of it: the underlying system
libraries a device backend needs (ghostscript, cairo, specific font sets)
aren't guaranteed identical across runner images, so a plot-export test can
fail on one OS and pass on another with zero code difference and the same R
version. Treat a matrix-only, single-OS failure as a real signal about
environment capability, not as flakiness to rerun away.

**How to check**: when a matrix job fails on exactly one OS leg while
identical R-version legs on other OSes pass, check whether the failing test
involves a graphics device (`postscript()`, `cairo_ps()`, `pdf()`, `svg()`)
before assuming a logic bug. `grep -rn "postscript\|cairo_ps\|grDevices::"
tests/` and cross-reference against what the failing OS runner image
actually ships.

**Incident**: `mufflyt/fpmrs-bibliometrics` run `32097236992` (2026-08-18):
`Test (R release / ubuntu-latest)` passed, `Test (R release / macos-latest)`
failed — same R release, same commit. The actual failure: `Error
('test-figure-export.R:156:3'): EPS is written as a vector file` / `Error in
file(con, "r"): cannot open the connection` — `PASS 270 | FAIL 3 | ERROR 1 |
SKIP 5` on macOS vs. a clean pass on Ubuntu. The EPS file the test expects to
read back was never actually written on the macOS runner, consistent with a
missing or differently-configured device backend on that image rather than
any change in the test's own logic.

---

## 41. Pattern-matched mutation testing needs its own staleness/ambiguity check, and that check's failures need a remediation owner — not just a correct hard-fail

**Rule**: a mutation-testing harness that injects each mutant by matching a
text/regex pattern against the *live* source (rather than an AST transform
or an explicitly marked mutation site) is exposed to a decay mode neither
item 10 nor item 5 fully covers: normal, unrelated refactoring can silently
invalidate a mutant definition two ways — the pattern **stops matching at
all** (STALE: the code it used to target has moved/changed) or **starts
matching more than once** (AMBIGUOUS: the harness can no longer tell which
occurrence is the intended mutation site). Treating STALE/AMBIGUOUS as a hard
failure (not a skip) is the *correct* design — a mutant the harness can't
plant proves nothing, same principle as item 5 — but a correct hard-fail is
not the same as a *maintained* one. If nobody owns updating the mutant
catalogue as the source evolves, this becomes exactly the kind of
permanently-red, ignored check item 20 warns about, except the underlying
cause here is routine code change, not flakiness.

**How to check**: for a pattern-based mutation harness, does it explicitly
distinguish `KILLED` / `SURVIVED` / `STALE` / `AMBIGUOUS` outcomes (not just
pass/fail), and does STALE/AMBIGUOUS fail the build rather than being
silently dropped from the denominator? Separately: `gh run list
--workflow=<mutation-job>.yml --json conclusion,createdAt` — if the same
mutant name has appeared in failure output across many consecutive runs, the
catalogue itself needs maintenance, and someone needs to be paged for that
specifically, not just for "the job is red."

**Incident**: `mufflyt/mysterymaps`'s `Scientific Nightly` workflow failed
every day from at least 2026-08-17 through 2026-08-27 (11+ consecutive days,
confirmed via `gh run list`). Root cause, confirmed identical across 6
sampled runs spanning 6 days: the `mutation-assault` job's catalogue has 3 of
20 registered mutants gone bad — `inf_missing_from_legend` and
`na_legend_suppressed` both STALE ("pattern no longer present in the
source"), `s2_left_off` AMBIGUOUS ("pattern matched more than once; set
all=TRUE or narrow it") — while the other 17 mutants still correctly report
`KILLED`. The harness's own design is sound (`##[error]mutant
\`inf_missing_from_legend\` is STALE: pattern no longer present in the
source` — an explicit, correctly-classified hard failure, not a silent
drop), but the catalogue drift itself has gone unaddressed for at least 11
days, meaning the repo has been carrying an accurate-but-ignored red signal
the entire time.

---

## 42. A function name defined at top level in two different files decides its behavior by source order, not by intent — guard the class, not just the instance that already bit you

**Rule**: R has no compile-time duplicate-symbol error. If `foo <- function(...)`
exists at top level in two different files that both get `source()`d into the
same environment, whichever runs *last* silently wins, and nothing generic
catches this — only a check built for that one specific function name. A
guard added after the first instance ("no second definition of `X`") protects
`X` and nothing else; the same mistake recurs under a different name the next
time a function gets extracted into a module and the old copy isn't deleted.

**How to check**:
```bash
# top-level `name <- function(...)` assignments across production R/,
# excluding archives — collisions are lines with count > 1
grep -rhoE '^[A-Za-z_.][A-Za-z0-9_.]* *<- *function' R/ --include='*.R' \
  | grep -v '/@archive/' \
  | sed -E 's/ *<-.*//' | sort | uniq -c | sort -rn | awk '$1>1'
```
For each collision, trace which copy actually runs in production (does one
file `source()` the other into the same scope, with the later call winning?)
before assuming either is dead code.

**Incident**: `mufflyt/isochrones`, 2026-08-28 — found three separate
instances of this exact pattern in one session, not one: `haversine_distance()`
(pre-existing, already a named incident in this repo's own
`spatial-units-and-library-contract.yml`), `compute_raster_overlap_allocation()`
(`R/08-area-weighted-overlap.R`'s copy had none of `R/step8_modules/overlap_engine.R`'s
adaptive rasterization, OOM-guard chunking, or the R147 fix for a real
performance regression — and was silently shadowed at runtime by a
`source(..., local = TRUE)` call later in the same file), and `sprintf_safe()`
(`R/log_safe.R`'s documented "never fails" version vs. `R/log_glue_safe.R`'s
unconditional alias to a different implementation with a different contract
on a placeholder-count mismatch). Each existing guard test protected exactly
one prior function name; extending the guard to a fourth, fifth, or sixth
collision would have required noticing each one by hand, same as this session
did, rather than a single sweep catching the whole class.

---

## 43. A negative-control test existing and passing locally is not the same as CI ever running it — verify the file is actually wired into a workflow's file list

**Rule**: item 10 establishes that a meta-gate needs a mutation-tested sibling
proving it fires. That sibling test still provides zero protection if no
workflow's test invocation actually includes it — a curated `test_files <-
c(...)` list (see item 2's same shape, one level up: not just "does this
package get installed" but "does this test file get *run* at all") does not
grow automatically when a new file is added to `tests/`. Writing the test is
necessary; confirming it is reachable from a real CI trigger is a separate,
easy-to-skip step.

**How to check**: for a new or updated meta-gate test file, grep every
workflow for its path:
```bash
grep -rl "test-your-new-file\.R" .github/workflows/
```
No hits means the file exists, may pass every time it's run by hand, and
never runs in CI at all. Separately confirm the workflow(s) it *is* wired
into actually trigger on `pull_request` (not `schedule`-only — see item 1) —
a test correctly wired into a nightly-only workflow still leaves a same-day
regression unguarded until the next scheduled run.

**Incident**: `mufflyt/isochrones`, 2026-08-28 — a new negative-control test
for `scripts/ci_hygiene.R` (written to close the item-10 gap found in this
repo's own audit) passed cleanly under `testthat::test_file()` run by hand,
but the workflow that owns the script it tests (`hygiene.yml`) never invokes
any `testthat` file at all — it runs `Rscript scripts/ci_hygiene.R` directly,
by design, to stay dependency-free (its own header: "a check that costs
minutes is the check somebody switches off"). The only place a new
`tests/testthat/*.R` file gets picked up automatically is the sharded full
suite, which had been red for 9+ continuous days in this repo at the time —
relying on it alone for a brand-new gate's only signal would have meant the
gate effectively never ran. Fixed by adding the new file's path to
`nightly-smoke.yaml`'s existing curated `test_files` list, next to the
sibling gate-contract test it was modeled on, which does trigger on every
`pull_request`.

---

## 44. For persistent (non-ephemeral) self-hosted runners, add a scheduled health check for the runner's own toolchain — independent of any real CI job ever hitting the drift first

**Rule**: item 4 warns not to *assume* state carries over between sibling
jobs on a GitHub-hosted ephemeral runner. Self-hosted runners invert that
risk entirely: if `install-r: false` (or equivalent "assume it's already
here") is set anywhere, the runner's own toolchain persists across every
job, every workflow, and every day with nothing in the repo watching it.
Nothing about the repo's *code* has to change for a runner to drift out of a
working state — a manual `install.packages("pak")` on the box, a partial
OS-level R upgrade, anything. The first thing to notice should not be a real
job failing for what looks like an unrelated reason.

**How to check**: `grep -l "install-r: false" .github/workflows/*.yml` — if
any hits exist, is there a *separate*, scheduled (`on: schedule` +
`workflow_dispatch`), independent-of-any-real-job workflow that verifies the
runner pool's own toolchain health? Does it identify which specific runner
it landed on (hostname / `$RUNNER_NAME`) in its output, so a problem confined
to one box in a multi-runner pool is traceable across the schedule's history
rather than reading as an intermittent flake?

**Incident**: `mufflyt/isochrones`'s `secrets` workflow crashed on
`isochrones-ci-runner-1` on 2026-08-26 — `Error in load_private_package("cli")
: Cannot load cli from the private library`, dead in 31 seconds, before the
credential scan it exists to run ever started. R on that runner was 4.5.2;
`pak`'s own bundled private `cli` had been installed under R 4.5.3. Nothing
in the repo's code or that day's commits caused it — the runner's own state
had simply drifted. No workflow in the repo checked for this independently;
it was found only because a real job happened to hit it. Fixed by adding
`runner-health-check.yml`: a `schedule`-triggered job (every 6 hours),
fanned out to 4 parallel replicas per run to raise the odds of covering more
than one runner in the pool per run (a single scheduled job can only land on
whichever runner is idle, not "every runner" — see item 37's own sibling
concern, item 4, for the same single-runner-per-job constraint applied here
to a monitor rather than a real job).

---

## 45. When building a NEW compatibility/health check, exercise the real failure path directly — a metadata comparison (a recorded version string, a `Built:` field) is not equivalent, in either direction

**Rule**: it's tempting to diagnose a suspected version-compatibility problem
by comparing recorded metadata (a package's `Built:` R version, a config
file's declared version) against the current environment, because it's cheap
and doesn't require reproducing the actual crash. That comparison can be
wrong both ways: too loose (two versions differ and it still works fine in
practice — most packages tolerate a patch-level R bump) and too strict
(flagging a mismatch that has never actually caused a problem, training
people to ignore the check — the exact failure mode item 20 warns about).
When the real operation is available to invoke directly and cheaply, prefer
it over inferring compatibility secondhand.

**How to check**: for a new health/compatibility check, ask: does the
package or tool already ship its own self-diagnostic (e.g. `pak::pak_sitrep()`,
`renv::status()`, `torch::install_torch()`'s own verification), and does the
check call that directly rather than parsing a version string and asserting
equality?

**Incident**: `mufflyt/isochrones`, 2026-08-28 — the first draft of the item
37 runner-health-check compared each critical package's recorded `Built:` R
version against `getRversion()` and rejected any patch-level mismatch. That
produced a false positive on the very first machine it was tested against:
`dplyr` built under R 4.6.0, running under R 4.6.1, working perfectly fine in
practice (ordinary R patch releases do not reliably break package ABI
compatibility). The real incident this check exists to catch (item 37) is
narrower and stranger than a generic version mismatch — `pak`'s private
library bundling specifically, evidently more version-sensitive than typical
package installs. Rewritten to call `pak::pak_sitrep()` directly (which
exercises the exact private-library load that crashed) and check its printed
output for the literal success line ("Dependencies can be loaded") rather
than infer compatibility from a version string; verified against both a
simulated crash and simulated non-success output before trusting it.

---

## 46. A blocking scientific test must prove it fails on a planted defect and passes when reverted — before you trust it, not just after it's written

**Rule**: writing a scientific-correctness test and watching it pass is not
evidence the test works — it might be vacuously true, checking the wrong
thing, or unreachable. Before a test is allowed to block CI (or before you
report a fix as verified), plant the actual defect it's meant to catch,
confirm the test fails, revert the defect, and confirm the test passes
again. Passing the first time proves nothing; failing-then-passing on a
real mutation is the only thing that does.

**How to check**: for every blocking scientific test you write or modify,
show both runs — the red run against the planted defect and the green run
against the fix — not just the final green state. A test whose failure mode
has never been observed is unverified, regardless of how long it has been
green.

**Incident**: this is a standing rule adopted after a CI-hardening session
on `isochrones` that fixed two real, previously-silent regressions the same
day — a 12-day production crash (`R/08-area-weighted-overlap.R` missing the
`main()` entry point its production `callr` invocation contract requires)
and a two-month-silent deletion of `retirement_decision_log`, an audit-trail
column, from `build_decision_logic_cte()`. Both survived undetected because
nothing had actually exercised the code path that broke — mocked tests for
the former, a real regression test whose `source()` call threw before
reaching its assertions for the latter (masked behind a `skip()`, not a
`fail()`). Every fix in that session was verified the hard way: for the
`retirement_decision_log` restoration, the exact snapshot file was
regenerated by running the real test, not hand-edited and assumed correct
(a first hand-edited attempt guessed at numeric-interpolation formatting and
was wrong); for the Step 8 fix, `sys.nframe()` inside the real production
`callr::r(func=...){source(...)}` invocation pattern was measured
empirically (16, not the assumed 0) rather than reasoned about abstractly,
and both the direct-`Rscript` and callr paths were exercised locally before
either fix was called done.

---

## 47. An audit result capable of changing the study's frame needs independent confirmation before it's trusted — a single automated pass is not enough

**Rule**: most CI findings are local and low-stakes — a broken function, a
stale test, a missing guard. A different category of finding changes what
the study can claim: "this correction doesn't move the temporal conclusion,"
"this cohort is still representative," "this data gap doesn't affect the
headline number." That kind of result is exactly the kind most likely to be
wrong in a way that matters, because it's usually produced by the same
single pass (one script, one audit, one AI investigation) that found the
underlying issue in the first place — and confirmation bias runs in the
direction of "the fix is fine, ship it." Before letting an audit result
downgrade a finding from "this changes the science" to "this doesn't," get
independent confirmation: a second method, a second reviewer, a second tool,
or at minimum a deliberately adversarial re-check by someone who didn't
write the original fix.

**How to check**: when a CI or audit result includes a framing claim — "the
conclusion holds," "no material impact," "still within tolerance" — ask who
verified that claim and how many independent ways. One script producing both
the correction and the verdict on its own materiality is not independent
confirmation, even if the script is correct.

**Incident**: `isochrones`' Connecticut GEOID/E2SFCA population-surface
correction (`docs/TECHNICAL_APPENDIX_CT_E2SFCA_GEOID_BREAK_2026-08-16.md`,
commit `a631aa226`, "bound the Connecticut correction — the temporal
conclusion holds") is exactly this shape: a real, measured data-repair
(Connecticut was missing from the 2022/2023 E2SFCA population surface) paired
with a single-pass verdict that the repair doesn't change the manuscript's
temporal-access conclusion. That verdict is plausible and may well be
correct, but this checklist's own item 33 ("an identical failure signature
surviving a targeted fix is evidence against the theory") and item 45
("exercise the real failure path directly, not a proxy for it") both apply
here in spirit: a framing claim of this kind is exactly the kind of result
that should be independently reproduced — a second, differently-built check
of whether the corrected denominator moves the conclusion — before treating
it as settled, not accepted on the strength of the same pass that discovered
the correction.

---

## Quick audit script skeleton

```bash
#!/usr/bin/env bash
# Run from inside each repo. Not exhaustive -- a starting point per item above.
set -u
echo "== 1. Tiering: does pull_request trigger a comprehensive suite, or only schedule? =="
grep -B2 -A5 "^on:" .github/workflows/*.yml

echo "== 3. Fresh-clone hygiene: any test reading /tmp or a hardcoded home path? =="
grep -rn "/tmp/\|/Users/\|~/\|Sys.getenv(\"HOME\")" tests/*.R 2>/dev/null | grep -v tempfile

echo "== 9. Stale claims in comments =="
grep -rn "fails in a fresh clone today\|currently fails\|for now\|as of 20" .github/workflows/*.yml

echo "== 10. Meta-gates without a *_detect.R sibling =="
for f in tests/ci_*.R tests/test_*_gate*.R 2>/dev/null; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .R)
  detect="tests/test_${base#ci_}_detect.R"
  [ -f "$detect" ] || echo "no detect-sibling found for $f (expected something like $detect)"
done

echo "== 12. Steps with no visible budget/timeout =="
grep -B3 "run: |" .github/workflows/*.yml | grep -c "BUDGET="

echo "== 13. Jobs in the workflow vs. jobs required by branch protection =="
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner)
grep -h "^    name:" .github/workflows/*.yml | sed 's/^    name: //' | sort -u > /tmp/wf_job_names.txt
gh api "repos/$repo/branches/main/protection" --jq '.required_status_checks.contexts[]' 2>/dev/null | sort -u > /tmp/required_checks.txt
echo "in workflow but NOT required (check deliberately, not by accident):"
comm -23 /tmp/wf_job_names.txt /tmp/required_checks.txt

echo "== 14. Rolling (non-pinned) package mirrors =="
grep -n "packagemanager.posit.co.*/latest\|pypi.org/simple\b" .github/workflows/*.yml

echo "== 15. Missing concurrency cancellation =="
for f in .github/workflows/*.yml; do
  grep -q "^concurrency:" "$f" || echo "no concurrency: block in $f"
done

echo "== 16. No explicit permissions: block =="
for f in .github/workflows/*.yml; do
  grep -q "^permissions:" "$f" || echo "no top-level permissions: block in $f (using default token scope)"
done
```
---

*Compiled 2026-08-28 from the midwifery repo's CI-hardening session
(PRs #93, #94; branch-protection fix applied directly to `main`) — every
incident cited above is a real failure from that
session, not a hypothetical.*

*Items 22-25 added 2026-08-28 from a separate CI-hardening session on the
private_equity repo, applying this checklist against its actual workflows
(items 1-21 were audited too; most were structurally not applicable there —
no path-filtered triggers, no cross-job state sharing to audit — and are not
re-cited to avoid implying a false incident). Each of 22-25 is, likewise, a
real failure from that session, not a hypothetical.*

*Items 26-28, and the `covr` addendum to item 21, added 2026-08-28 from a
CI-hardening session on the `simulation` repo, triggered by a direct
"why does this keep breaking" investigation of its nightly workflow. Two
long-standing failures (the `coverage` job red on every run for 10+
consecutive nights, and a growing GitHub issue collecting a near-daily
comment) were root-caused, not just described: the fix for item 26's
incident was verified by reproducing the exact CI failure locally (`covr`
with `clean = FALSE` to preserve its normally-deleted failure output),
confirming 26 failures across 12 files before the fix and 0 after. Item 27's
incident was independently confirmed live: `gh api repos/OWNER/REPO/pages`
returned 404 before the fix and the expected site metadata after.*
*Items 29-35 added 2026-08-28 from a multi-day CI-hardening session on the
`isochrones` repo, centered on standing up a genuinely working self-hosted
GitHub Actions runner (EC2, webhook-triggered auto-start, idle-based
auto-stop) and then stress-testing it until it stopped breaking. That
runner's defining property — state persists across jobs, unlike a
GitHub-hosted runner — is the root cause behind five of these seven items
(29-33); the other two (34, 35) surfaced from applying this same checklist's
own items 3, 6, and 9 against the session's own just-written data-regression
test suite and a genuinely concurrent second Claude Code session working the
same branch. Every incident cited in 29-35 is a real failure hit and fixed
during that session, confirmed via a passing rerun, not a hypothetical.*
*Items 36-41 added 2026-08-28 from four parallel investigations covering
`isochrones`, `mysterycall`, `cliff`, `twostep`, `mufflyaccess`,
`mysterymaps`, `isochrones-ci`, `fpmrs-bibliometrics`, `researchpaths`,
`grace-ent`, `sling-volume-patterns`, and `isoaccessr` — every `mufflyt/`
repo with CI beyond the four already covered by items 1-28. Each item is
root-caused against real run logs (specific run IDs, exact error text), not
inferred from reading workflow YAML alone. Several leads were investigated
and explicitly NOT written up because the evidentiary bar wasn't met: a test
sharding pattern in isochrones' `suite-sharded.yml` (structurally interesting,
no tied failure found in the time available), a `render-proposal` failure
pattern in `isoaccessr` (plausibly the same class as item 27, but the actual
run logs were past GitHub's retention window and couldn't be confirmed rather
than guessed), a one-off 44-minute `setup-r-dependencies` hang in
`mysterymaps` (real, but a single occurrence rather than a pattern), and
`twostep`'s permanently-failing nightly SSOT test (real, but the same shape
as item 20 rather than something new). `researchpaths`, `grace-ent`,
`sling-volume-patterns` had no failure history worth investigating (too new,
or an abandoned branch with no resolution to extract a lesson from).*
*Items 42-45 added 2026-08-28 from the same isochrones CI-hardening session
that produced this file's items 1-12 audit against `mufflyt/isochrones`
directly (a separate exercise from the four-repo sweep behind items 29-34,
run the same day). Items 4 and 10 from that audit were fixed in the same
session, not just described: item 4 via `runner-health-check.yml` (the
subject of item 44), item 10 via a new negative-control test for
`scripts/ci_hygiene.R` (the subject of item 43, which is also where that
fix's own wiring gap was caught and closed). Item 45 documents a mistake
made and corrected while building item 44's fix, in the same session, not a
hypothetical caution.*

*Items 46-47 added 2026-08-28, adopted as standing meta-rules from a
`mufflyt/isochrones` retirement/Step-8 CI-hardening session (the same one
behind items 42-45), after fixing two real, previously-silent regressions
(a 12-day production crash, a two-month-silent audit-trail deletion) that
both survived because nothing had exercised the failing code path for real.
Item 47's incident is not a hypothetical — it names a specific, real audit
result from that repo (`a631aa226`) as an example of the pattern to guard
against, not a defect being claimed against it.*
