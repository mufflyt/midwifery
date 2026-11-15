# Technical appendix — migrating the `mysterynpi` pin from `ac42561b` to `691daaf`

**Status:** dependency upgrade and differential audit. **No canonical FROZEN
artifact, manifest or cohort is modified by this work.** Whether the corrected
package semantics should change the published study population is a separate,
separately audited decision; see *Recommendation on promotion* at the end.

---

## 1. What went wrong, and how it was found

Two AMCB–NPPES linkage freezes built three days apart from **byte-identical
input** differed by 123 cohort members:

| freeze | date | rows | cols | cohort members | class-5 held out |
|---|---|---:|---:|---:|---:|
| `dbcc76f4…` | 2026-08-10 | 22,309 | 54 | 16,898 | 153 |
| `1a7bd6a8…` | 2026-09-10 | 22,357 | 60 | 17,028 | 153 |
| `9f224007…` *(current)* | 2026-10-22 | 22,357 | 60 | **16,775** | **163** |

Nothing in this repository explained the movement. The pipeline code was
unchanged on the relevant path, the roster scrape was the same, and the panel
hash matched. The difference came from **underneath** the pipeline: the
`mysterynpi` package, which owns every name normalisation and agreement rule
the matcher uses, had changed semantics without a `NEWS` entry.

### 1.1 The first hypothesis was wrong, and that is the lesson

The initial suspects were `norm_name()` and `first_initial()`. Both were
refuted by measurement:

* `first_initial()` **was never called** on the path in question.
* Both revisions of `norm_name()` resolve to the same thing —
  `mysterynpi::name_key(x, strip_alternates = TRUE)`.

A second claim — that the pinned package could not reproduce `9f224007` — was
also wrong, and wrong for an instructive reason: the test exercised
`name_key()`, but the column that moved (`normalized_middle_name`) comes from
**`split_given()`**. Measured properly, the pinned package reproduces
`9f224007` at 22,357/22,357 on both columns.

Selective reasoning about which function *ought* to matter is what cost those
days. [`audit_mysterynpi_migration.R`](../audit_mysterynpi_migration.R) is
written to be exhaustive instead: it probes **every** `mysterynpi` entry point
the matcher can reach and lets the diff decide.

### 1.2 The two real causes

**`cb86e56` (2026-09-13) — `split_given()` began stripping `[.,]`.**
`"Oluwatope B."` yields middle `"B"` rather than `"B."`; `"Sr. Mary"` yields
given `"SR"` rather than `"SR."`. The rule is **correct** — an initial and the
same initial with a period are one initial — and it is already in the old pin.
It accounts for all **1,278** normalised-middle-name and **129** given-name
differences between the freezes, with **zero residual**.

**`503a37e` — the tokenizers stopped splitting on a hyphen.** This is correct
where it was aimed and wrong where it was not, and the asymmetry is the whole
finding:

> In `person_matches()` a shared token is evidence **for** a match, so
> over-splitting `"Mary-Jane"` into `MARY`/`JANE` manufactures a false positive
> against an unrelated `"Jane"`. `503a37e` is right to refuse that.
>
> In `middle_agreement()` a token mismatch is evidence **against** — it
> **vetoes** a candidate — so under-splitting manufactures a false **negative**,
> and the veto is silent.

The measured cost: AMCB certificant **CNM04881**, roster middle name
`"Marie-Lefever"`, against an NPPES record carrying `"MARIE LEFEVER"` in
**eight consecutive annual snapshots**. One token versus two share nothing, so
`middle_agreement()` returned `"conflicts"`, the only candidate was vetoed, and
a correctly identified midwife was published as `"unmatched"` —
indistinguishable from someone absent from the registry entirely. Same person,
same name, different punctuation.

### 1.3 Identifying the exact build that produced the freeze

The revision that built `9f224007` was found by observation on the machine that
built it, not by inference: **mysterynpi 0.7.0, built 2026-09-28 20:02:43 UTC,
`Packaged … tmuffly`, no `RemoteSha`**. It reproduces both `9f224007`
behaviours. That it took machine archaeology to answer "which matcher built
this freeze?" is why provenance sidecars now record the version **and source
commit** of every package whose name semantics can move a result — see §5.

---

## 2. The upstream fix (`mysterynpi` 0.9.0)

Two PRs, both merged:

| PR | merge SHA | what |
|---|---|---|
| [#48](https://github.com/mufflyt/mysterynpi/pull/48) | `8fc2ecf25a8bcba518bea44709ae4f19321dc118` | DuckDB lambdas off the deprecated `->` arrow — unblocked a fully red CI matrix |
| [#47](https://github.com/mufflyt/mysterynpi/pull/47) | `691daaf99bb9a5fd44c3e1907fcfc017169105ba` | the scientific correction, `Version: 0.9.0` |

### 2.1 Why #48 had to come first

`eae56b8` passed on 2026-10-10 and **the same commit failed its scheduled run
on 2026-11-09** with `Binder Error: Deprecated lambda arrow (->) detected`. A
DuckDB upgrade began rejecting the syntax outright, erroring all 14
DuckDB-backed tests and turning the whole matrix red — including the mutation
campaign's control gate. No code in the package had changed. Fixing the name
rules on top of a red matrix would have made the correction unverifiable, so
the infrastructure failure was separated out and fixed on its own.

### 2.2 The correction: delegate, don't re-derive

Two attempts were discarded before the right one:

1. **Fold hyphens and corroborate on any shared token.** The package's own
   `test-tokens.R` failed it, correctly: `ANNE-MARIE` against an unrelated
   `MARIE` must still conflict.
2. **Require folded set *equality*.** Correct, but it handled only the
   hyphen-versus-space case.

Meanwhile `name_surname_match_type()` had been answering the same question more
completely all along:

| | verdict |
|---|---|
| `ERICKSON-OWENS` / `ERICKSON OWENS` | `separator_equivalent` |
| `ERICKSON-OWENS` / `ERICKSONOWENS` | `concatenated_equivalent` |
| `ANNE-MARIE` / `MARIE` | `component_subset` |

So `middle_agreement()` now asks that primitive. `exact`,
`separator_equivalent` and `concatenated_equivalent` corroborate.
**`component_subset` deliberately does not** — `503a37e` is right that
suppressing a veto on half a compound asserts a match on half a name.

The change is **strictly additive**: it is reached only after the whole-token
comparison has already failed, so it can turn `"conflicts"` into
`"corroborates"` but never the reverse, and it **cannot newly veto any
candidate**. `middle_tokens()`, `given_tokens()` and `person_matches()` are
untouched; that the `503a37e` false positive stays fixed is asserted directly
in the contract test, not assumed.

Not edit-distance tolerance: `"none"` falls through to the existing cascade, so
`JULIA`/`JULIE`, `LEE`/`LEA` and `ANN`/`ANNE` still conflict.

### 2.3 Upstream measurement, full corpus

Over this study's entire pre-veto candidate corpus — **319,744** roster ×
registry name-variant comparisons, **306,138** distinct candidate pairs — the
delegation changes **9** middle-name verdicts against the set-equality version
and lifts **8** candidate vetoes, adding **none**:

| roster | registry |
|---|---|
| `MARIE-LEFEVER` | `MARIE LEFEVER` |
| `DE BRUIJN` | `DEBRUIJN` |
| `RAEANNE` | `RAE ANNE` |
| `VANHORN` | `VAN HORN` |
| `DE'JOURA` | `DEJOURA` |
| `RENE` / `RENEE'` / `JENEE` | `RENE'` / `RENEE` / `JENEE'` |

Every one is the same name differently punctuated. The hand-rolled fold caught
only the first row; the apostrophe and separator-free cases came free with the
primitive that already owned them.

**A lifted veto restores candidacy, not a match.** The candidate re-enters
ranking and must still win on the evidence. This distinction is why a verdict
count is not a membership count, and why §4 exists.

---

## 3. Three surname classifications changed — and cannot move this cohort

Between `0.3.1.9000` and `0.9.0`, `surname_agreement()` disagrees with itself on
exactly three of 3,000 real roster/registry pairs (0.1%):

| pair | `0.3.1.9000` | `0.9.0` | |
|---|---|---|---|
| `Erickson-Owens` / `ERICKSONOWENS` | conflicts | corroborates | correction |
| `Meslar-Little` / `MESLARLITTLE` | conflicts | corroborates | correction |
| `Gener Montan` / `GENER BETANCOURT` | corroborates | conflicts | tightening |

The first two are one surname spelled with and without its separator. The third
shares only its first component, where a married-name change and two different
people are indistinguishable — conflicting is the conservative reading, and
this function must not choose between them.

**These three cannot affect an AMCB linkage decision.** `surname_agreement()`
appears **nowhere** in `match_amcb_to_npi.R`, `R/amcb_match_rules.R` or
`R/amcb_name_keys.R` — established by enumerating every `mysterynpi::` and
`amcb_*` symbol in all three files, not from memory. Its only consumers here
are `experiment_trilliant_identity_linkage.R` and `R/lib/trilliant_identity.R`.
They are recorded because incidental package drift is exactly what caused the
original 123-row mystery, **not** because they move a cohort member.

The surname-side functions that *can* move a decision are different ones, and
the audit covers them: `blank_na(..., fold_hyphens = TRUE)` (the blocking key),
and `surname_tokens()` / `surname_token_table()` (class-5 eligibility).

---

## 4. The differential audit

[`audit_mysterynpi_migration.R`](../audit_mysterynpi_migration.R) runs both
pinned versions against **the same corpus**, with the input hashes recorded in
each probe directory and the diff **refusing to run** if they disagree — two
probe runs over different bytes would be uninterpretable.

Differences are bucketed, because these are not the same question:

| bucket | meaning |
|---|---|
| `representational` | the normalised string moved, but no decision reads it |
| `blocking` | a key the matcher JOINs on moved → candidate pairs can appear or vanish |
| `evidence` | a name-agreement verdict moved |
| `class5` | the surname-component index moved, i.e. class-5 eligibility |
| `parse` | `parse_person()` output moved, in shape or content |

One methodological trap is worth naming: the pre-veto corpus must be
reconstructed from roster × panel on exact-surname blocks. It **cannot** be
read from `artifacts/linkage_candidate_audit.csv`, which is written at
`match_amcb_to_npi.R:709`, **after** `filter(mid_conflict == 0L)` — a vetoed
pair is already absent, so a veto being *lifted* is invisible. A first attempt
at this comparison used that artifact and reported zero changes.

Each probe run also rebuilds its **own** blocks, because
`blank_na(fold_hyphens=)` is itself under comparison; a shared corpus built
from one version's keys would hide any pair only one version blocks. Keyset
differences are therefore reported separately from verdict differences.

---

## 4a. Results: the full-corpus differential

Run 2026-11-14 over freeze `9f224007…` and panel `6b9696ce…`, both pins against
the same bytes. **22,357** roster rows x **527,756** registry name variants,
**333,866** candidate pairs.

| bucket | column | changed | of | % |
|---|---|---:|---:|---:|
| blocking | `bn_lastfh` | 56 | 527,824 | 0.011% |
| blocking | `sg_mid` | 18 | 527,824 | 0.003% |
| representational | `nk_mid` | 68 | 527,824 | 0.013% |
| representational | `nk_last` / `nk_alt` / `bn_last` / `spar` | 56 each | 527,824 | 0.011% |
| representational | `snn` | 59 | 527,824 | 0.011% |
| representational | `nk_first` | 18 | 527,824 | 0.003% |
| evidence | `mt_mid` (panel) | 724 | 527,824 | 0.137% |
| evidence | `gt` (panel) | 2,112 | 527,824 | 0.400% |
| evidence | **`mid`** | **49** | 333,866 | 0.015% |
| evidence | `pm` | 133 | 333,866 | 0.040% |
| evidence | `nst` | 1,187 | 333,866 | 0.356% |
| class5 | `st_last` | 54 | 527,824 | 0.010% |
| parse | SCHEMA | — | — | `new[suffix]` |

**The candidate pair set is identical.** There is no `KEYSET` row: despite 56
blocking-key changes, not one candidate pair appears or vanishes between the
two pins. Candidate *generation* is unaffected.

### The 49 middle-name verdict changes, and why the net runs the "wrong" way

The new pin produces **more** conflicts, not fewer — 151,280 against 151,251.
That is the opposite of what the 0.9.0 release note alone implies, and the
reason is that the release note measures 0.8.0 -> 0.9.0 while this repository
moves 0.3.1.9000 -> 0.9.0, which also carries `503a37e`:

| change | n | character |
|---|---:|---|
| `corroborates` -> `conflicts` | **27** | compound vs half: 14 against a full half-token, 13 against a single initial |
| `uninformative` -> `conflicts` | **12** | **dirty registry data — a defect, see below** |
| `conflicts` -> `corroborates` | **10** | the punctuation corrections, incl. `CNM04881` |

**The 27 are `503a37e` working as designed.** `GAIL-ROSANNE` vs `GAIL`,
`ROSE-MARIE` vs `MARIE`, `LEE-ANN` vs `ANN` — a compound against one half of
itself. Refusing to corroborate these is the conservative reading, and
`component_subset` is deliberately excluded from the corroborating verdicts for
exactly this reason. 13 of the 27 are a compound against a single *initial*
(`ANNE-LEWIS` vs `L`, `SHABAD-JIT` vs `J`), where the initial plausibly
abbreviates the compound's second component; those are the most arguable of the
set and are flagged here rather than settled.

**Each of these 27 is a candidate veto ADDED.** A veto removes a candidate, so
this direction can *remove* cohort members — the opposite of the `CNM04881`
fix. Any claim that the correction "adds no vetoes" is true of 0.8.0 -> 0.9.0
and **false of the pin move this repository actually makes**.

### The 12 were a defect, found here and fixed upstream

All twelve are junk in the registry's middle-name field:

| recorded value | rows |
|---|---:|
| `"646-704-2003"` — a phone number | 11 |
| `"-"` — a bare hyphen | 3 |

Digits are separators in the token class, so the phone number collapsed to the
token `"-"`. Punctuation is not a name, but it is not an empty string either, so
`nzchar()` admitted it and it reached `middle_agreement()` as a name that
**disagrees** — vetoing the candidate.

That inverts the function's own documented contract: `"uninformative"` is what
absence yields, and absence "must never be read as evidence of difference." A
dirty registry field was silently deleting matches.

Fixed in **mysterynpi 0.9.1** ([#49](https://github.com/mufflyt/mysterynpi/pull/49)):
a token must contain a letter, which subsumes `nzchar()`, applied to
`middle_tokens()`, `given_tokens()` (whose `>= 2` character filter dropped a
bare `"-"` but not `"--"`) and `name_leading_given()`. Every input carrying a
letter tokenizes exactly as before, so the 0.9.0 corrections are untouched and
asserted so.

### Where the per-record detail lives

`qa/mysterynpi_migration/` — `summary.csv` plus one file per changed column,
each row naming the `amcb_id` and `npi` affected. **`qa/` is gitignored**,
because those rows are person-level by construction. Regenerate with the
recipe in §8.

---

## 4b. The shadow rebuild needs two shadow arms, not one

The first shadow design — rebuild with the new pin, compare to `9f224007` —
**cannot isolate the package change**, and the pipeline said so on its first
line of output: `AMCB rows: 22,309` against the freeze's 22,357.

Three independent confounds, all already documented in the README's
*"The frozen cohort cannot be regenerated by the current pipeline"*:

1. **Roster vintage.** On-disk `midwives.csv` holds 22,309 rows and is dated
   2026-08-14; `9f224007` was built from a 2026-09-02 scrape of 22,357.
2. **The bijection changed outside this repository.** `rank_one_to_one()`
   stopped consuming NPIs greedily on 2026-08-08.
3. **`FROZEN` is not the matcher's output.** It is the base linkage plus a
   class-5 guard applied afterwards, which is where the held-out rows come
   from.

So a shadow-versus-freeze comparison hands every membership difference four
candidate explanations — the same confounding this appendix refuses for the
vendored resolver in §7.

**The correct design is shadow versus shadow:** both pins run against the same
on-disk roster, so the package is the only thing that varies. Neither arm will
equal the freeze, and that is fine — the question is the *difference between
the arms*, not either arm's distance from a cohort built from inputs that no
longer exist on this machine.

Arm 2 (new pin) is built. Arm 1 (old pin) is outstanding, and **until it exists
the effect on accepted NPIs and cohort membership is unmeasured.** The
function-level differential above stands on its own because it reads the roster
side *from the freeze itself*, on exactly the right 22,357 population, with
everything but the package held constant.

---

## 5. Provenance: the question that cost days is now one field

`R/lib/artifact_provenance.R` records, in every artifact's sidecar, the version
and source commit of each package whose name semantics can change a result:

```r
SEMANTIC_PACKAGES <- c(
  "mysterynpi",     # name_key, split_given, middle_tokens, middle_agreement
  "stringi",        # transliteration; name_key() stops without it
  "humaniformat"    # person-name parsing under mysterynpi::parse_person()
)
```

A CRAN package reports `source_sha = NA`, which is the honest answer — the
version alone identifies a CRAN source. A package that is **not installed**
appears with `installed = FALSE` rather than being omitted, so "absent" and
"never asked" cannot look alike. `tests/test_semantic_package_fingerprint.R`
pins all of this (T1–T12).

---

## 6. The `parse_person()` suffix column, and a tripwire that worked

`parse_person()` at the new pin returns a **fourth** column, `suffix`, lifted
by its own `extract_suffix()` before `strip_name_noise()` can delete it as
noise.

`T1b` in `tests/test_amcb_name_keys_saboteur.R` asserted the column set was
exactly `first/middle/last` and said in as many words: *"if mysterynpi ever
DOES start returning a suffix, say so instead of silently passing."* It went
red **on the pin bump** — not later, when a caller read `""` where it expected
`NA`. That is the test doing its job.

The expectation was **updated, not relaxed**:

* the set is still asserted **exactly**, so a fifth column is still red tomorrow;
* new **T1c** proves the shim's NA conversion actually reaches `suffix`
  (`"Jane Q Public Jr"` → `"JR"`, absent → `NA`).

`amcb_parse_person()`'s conversion was already column-agnostic
(`out[] <- lapply(out, ...)`), so the new column inherited the NA contract for
free — now asserted rather than assumed. No non-test caller reads `$suffix`;
it is carried rather than dropped, because dropping it is precisely the silent
discard T1b exists to prevent.

---

## 7. Recorded, not acted on: the vendored resolver

The new pin clears the `mysterynpi >= 0.8.0` floor that originally forced
`rank_one_to_one()` to be vendored into `match_amcb_to_npi.R`. The vendored
copy **stays**, and the header now says why: it is the function that produced
every frozen artifact this repository publishes, and swapping it for upstream's
`resolve_one_to_one()` in the same change that revises the name rules would
leave two candidate explanations for any difference in the output. If upstream
resolution is adopted, it goes in its own separately audited change, measured
against a freeze that differs only in that respect.

---

## 8. Reproducing this audit

```sh
# 1. the previous pin, into a library of its own so the current one stays intact
git -C ~/mysterynpi worktree add /tmp/mn-oldpin ac42561b46d400a7e62649ee0161313628d914e8
R CMD INSTALL --no-multiarch -l /tmp/lib_old /tmp/mn-oldpin

# 2. the current pin, exactly as CI installs it
Rscript -e 'remotes::install_github("mufflyt/mysterynpi@691daaf99bb9a5fd44c3e1907fcfc017169105ba", upgrade = "never")'

# 3. both probes, then the diff
Rscript audit_mysterynpi_migration.R probe /tmp/lib_old /tmp/probe_old
Rscript audit_mysterynpi_migration.R probe default      /tmp/probe_new
Rscript audit_mysterynpi_migration.R diff  /tmp/probe_old /tmp/probe_new /tmp/report

# 4. the shadow rebuild, in a worktree of its own, canonical artifacts untouched
git worktree add --detach /tmp/mw-shadow <this-branch>
ln -s "$PWD/midwife_panel.csv" /tmp/mw-shadow/midwife_panel.csv
ln -s "$PWD/midwives.csv"      /tmp/mw-shadow/midwives.csv
cd /tmp/mw-shadow && Rscript match_amcb_to_npi.R
```

The shadow is isolated by construction, not by care: `OUT_DIR` is relative to
the working directory, the FROZEN CSV is gitignored so the shadow has no copy
to overwrite, and `freeze_cohort.R` refuses to write without `FREEZE_WRITE=1`.

---

## 9. Reconciliation targets

From `artifacts/amcb_npi_linkage_FROZEN.csv.manifest.json`:

| quantity | value |
|---|---:|
| rows | 22,357 |
| cohort members | 16,775 |
| class-5 candidates held out | 163 |

**These are historical reconciliation targets, not ground truth.** The shadow
rebuild should reproduce them only if the corrected semantics leave the
relevant decisions unchanged. Where it differs, the question is whether each
individual change is *justified* — never whether the counts can be made to
agree. Recovering the old 16,898-member cohort by adjusting name-matching rules
is explicitly not a goal: the goal is to establish which matches are correct.
