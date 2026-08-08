# Test coverage: current state and proposal

## Where we are

Before this change the repository had **no tests and no test tooling** — no
`tests/` directory, no `pytest`/`testthat` config, no CI workflow. Every file is
a top-level script that did its work as a side effect of being imported
(`main()` was called at module scope), so nothing was even *importable* for a
test to reach.

The code is small but not trivial: two Python scrapers and five R scripts, and
the interesting parts are subtle — a 500-row cap worked around by digit sweeps,
NPPES name-variant expansion, an evidence-tiered fuzzy matcher, a credential
gate re-implemented specifically for this cohort. These are exactly the places a
silent regression would corrupt 22k records without throwing an error.

## What this change adds (a starting point, not the finish line)

A first, runnable suite covering the pure logic that was cheapest to reach:

| Area | Function under test | Tests |
|------|--------------------|-------|
| `scrape.py` | `_text`, `parse_total`, `parse_rows`, `sweeps`, `Collector.bucket` | 13 |
| `fetch_npi_candidates.py` | `load_cache`, `build_candidate_rows` | 11 |

To make that possible, two behavior-preserving refactors were needed — and they
are themselves part of the proposal, because the rest of the codebase needs the
same treatment:

1. **Guarded the entry points.** `main()` now runs under
   `if __name__ == "__main__":`, so the modules can be imported without hitting
   the network. This is the single change that unblocks testing everything else.
2. **Extracted embedded transforms into named functions.** The HTML→row parser
   (`scrape.parse_rows`), the total parser (`scrape.parse_total`), and the
   NPPES-result→candidate-row transform (`fetch_npi_candidates.build_candidate_rows`)
   were lifted out of the request/`main()` bodies they were buried in. Pure
   functions with explicit inputs are testable; inline loops inside `main()` are
   not.

Run them:

```bash
pip install pytest
pytest
```

## Proposed priorities (highest value first)

### P0 — `credential_compatibility.R` (pure, high-stakes, zero deps)

This is the best test target in the repo and currently has none. Both functions
are pure, dependency-free, and gate every match decision:

- `normalize_credential_class()` — verify the **most-specific-class-wins** rule
  the code comments promise: `"CNM, RN"` → `midwifery` (not `nursing`);
  `"MD"` → `physician`; `""`, `NA`, `NULL`, `"XYZ"` → `UNKNOWN`; token splitting
  on non-alpha (`"CNM,MSN"` vs `"CNM MSN"` should agree).
- `are_credentials_compatible_midwifery()` — the truth table it documents:
  midwifery×physician → `FALSE`; midwifery×other_doc → `FALSE`; **UNKNOWN on
  either side → `TRUE`** (missing data is never evidence); midwifery×nursing →
  `TRUE`. A regression here either drops real matches or lets MD namesakes
  through.

Tooling: `testthat` + `R/` split, or a single `tests/testthat/test-credential.R`
that `source()`s the script. This needs R installed (it is **not** available in
the current environment, which is why these tests are proposed rather than
written here).

### P1 — the matcher's decision logic (`match_nppes.R`)

The scoring pipeline is where correctness actually lives, and it is the hardest
to test because it is one long script coupled to the external `isochrones` R
stack via `ISOCHRONES_R`. Proposal:

- **Extract `score_one()`-adjacent decision logic** the way the Python
  transforms were extracted, so the `Accept`/`Review`/`Ambiguous`/`No match`
  ladder can be exercised on hand-built candidate frames without the network or
  the 1.28M-row candidate table.
- Test the **evidence-tiered acceptance floors** directly: a 0.83 name score
  accepts on `strong` evidence but not `weak` (0.88) or `none` (0.95); the
  `none`-tier "sole candidate" exception; the `AMBIGUOUS` (0.02) tie-break that
  demotes near-equal rivals to `Ambiguous`.
- Test the **NPI-uniqueness demotion**: two certificants accepting the same NPI
  → the lower score drops to `Ambiguous`.
- Test the `.variation_score()` / `.maiden_score()` rescalers (0–30 → 0–1,
  0–0.8 → 0–1, `NA`/wrong-length → 0) — these are already small pure functions,
  just unexported.
- Keep a **fixture-based smoke test**: a dozen synthetic AMCB rows against a
  dozen synthetic candidates with a stubbed isochrones stack, asserting the
  final decision column. Guard the whole file with `validate_scoring_invariants`
  and `validate_pipeline_output`, which already exist — surface their pass/fail
  as an assertion, not just a printed line.

### P2 — Python network boundaries (contract tests, mocked)

`Session.connect/search/rows` and `nppes_query` are untested because they do
I/O. They don't need a live server — they need their **parsing and retry
contracts** pinned with mocked responses:

- `Session.connect()` extracts `p_instance` and the region id from the APEX home
  page — test against a captured HTML fixture; assert a clear failure when the
  markup shifts (right now a changed page yields an opaque `AttributeError` on
  `.group(1)`).
- `_request` retry/back-off: fails twice then succeeds, and reconnects only from
  the second attempt onward.
- `nppes_query` throttle math and the 4-attempt give-up returning `None`.

Inject a fake opener/`urlopen` (the `Collector.bucket` tests already show the
monkeypatch pattern).

### P3 — the R data-plumbing scripts (`geocode_midwives.R`,
`check_npi_deactivation.R`, `extract_nppes_midwives.R`)

These are join/reshape scripts over DuckDB and Excel/CSV. Highest-value units:

- **`geocode_midwives.R` address-hash + 5-digit zip fallback.** The canonical
  key is `lower(street)|lower(city)|STATE|zip`, with a `key5` fallback that
  strips the zip. Extract the hash builder and test: exact 9-digit hit wins over
  the 5-digit fallback; `NA` fields become the literal `"NA"` the cache expects.
- **`check_npi_deactivation.R` NPI type coercion.** The bug the comment records
  (NPI read as `double` vs `character` breaks the join) is a permanent
  regression risk — assert the join survives numeric-looking NPIs and that
  `deactivation_year` parses from the date substring.
- Run each against a tiny in-memory DuckDB / CSV fixture rather than the real
  9.8 GB / 1.4 GB sources.

### P4 — CI and a coverage gate

Add a GitHub Actions workflow that runs `pytest` (and `Rscript -e 'testthat::test_dir(...)'`
once the R suite exists) on push/PR. Start with a coverage **report**, not a
hard threshold, until the suite is broad enough that a number is meaningful.

## Notes / non-goals

- `dbg.py` is an interactive scratch script and is intentionally left untested.
- The isochrones matching stack (`parse_physician_name_enhanced`,
  `calculate_similarities`, the nickname dictionary, etc.) is a **separate
  project**; its tests belong there. Tests here should stub it and cover only
  the glue this repo owns — the credential gate, the evidence tiers, the
  acceptance ladder, and the data plumbing.
