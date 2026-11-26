# Dependency pin audit — mysterynpi across midwifery CI

Audit date: 2026-11-25. Approved upstream commit: `03469aed868ea6af1e429b1da033915e49010dc7` (phrase_key, v0.11.0).

## Pin inventory

| Location | Pin | Export assertion | Verdict |
|---|---|---|---|
| `.github/workflows/ci.yml:509` (r-suite install step) | `mufflyt/mysterynpi@03469ae…` | `stopifnot` on `strip_med_suffix`, `phrase_key`, `compact_name_key` exports | **Correct** — pinned to the approved commit, asserts the exact exports phrase_key callers need. Comment documents why (linkage dependency of several suites). |
| `.github/workflows/nightly.yml:170-176` (external-deps job) | same `03469ae…` SHA | same `stopifnot` triple | **Correct** — comment states "same pin as ci.yml, so the two jobs cannot answer differently." |
| `.github/workflows/nightly.yml:972` (informational package-deps job) | `mufflyt/mysterynpi@v0.2.0` | none | **Skew — accepted, documented.** v0.2.0 predates phrase_key (verified: `git show v0.2.0:NAMESPACE` has 0 `phrase_key` exports; it is an ancestor of `03469ae`). The job runs only three informational tests (`test_mysterynpi_contracts.R`, `test_cycle4_ct_apportionment.R`, `test_cycle12_names_territories.R`), none of which reference `phrase_key`/`compact_name_key` — verified by grep. The job "cannot redden the nightly," so even a future accidental phrase_key call fails soft. **Recommendation:** leave the pin (it intentionally exercises the public-release surface those tests were written against), but the comment should state explicitly that v0.2.0 lacks phrase_key so nobody "fixes" the skew by bumping the pin and silently changing what the tests verify. |
| `R/string_normalization.R:31-34` runtime guard | `packageVersion >= 0.2.0` | — | **Gap.** Necessary but not sufficient: mysterynpi 0.9.x/0.10.x would pass this guard yet lack `phrase_key`, and `normalize_name()`/`normalize_text()` would fail only at call time. The shim's own comment explains the ≥0.2.0 floor is for the `normalize_string` surface, which is accurate for *its* aliases — but phrase_key callers have no equivalent floor. |
| `normalize_name()` / `normalize_text()` guards | `requireNamespace` only | — | **Gap.** Unlike `street_key()` (`build_worksite_setting_crosswalk.R:58`) and `training_norm_school()` (`training_institution.R:42`), which assert export presence, these two check only that the package exists. Under a hypothetical 0.9–0.10 install the error surfaces deep inside a pipeline rather than at the guard. |

## Findings

1. **CI pins are consistent where it matters.** Both blocking jobs install the identical commit SHA and assert the three exports callers need. No CI correction required for correctness.
2. **Version floor gap (low severity).** `R/string_normalization.R` guards `>= 0.2.0`; phrase_key requires the 0.11.0 commit. No released tag covers 0.11.0, so a version comparison cannot express the real floor — the correct guard is export presence (`"phrase_key" %in% getNamespaceExports("mysterynpi")`), which two callers already use. Recommend extending that pattern to `normalize_name()`/`normalize_text()` guards, or adding a `>= 0.11.0` floor once a tag exists.
3. **Informational-job skew is intentional but undocumented.** nightly.yml's v0.2.0 install predates phrase_key by ~9 minor versions; safe today only because the three routed tests never call it. A one-line comment prevents a future well-meaning "pin alignment" from changing the surface under test.

## Correction applied

`nightly.yml` informational job: added a comment noting v0.2.0 intentionally predates phrase_key and the routed tests must not exercise it (see diff on this branch).
