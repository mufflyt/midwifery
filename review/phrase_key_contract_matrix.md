# Cross-repository normalization contract matrix — phrase_key / compact_name_key

Audit date: 2026-11-25. Upstream: `mufflyt/mysterynpi` @ `03469ae` ("feat: phrase_key(), the phrase-equality join key; 0.11.0"). Downstream: `mufflyt/midwifery` @ `origin/main` (`022d727`).

## Upstream contract (mysterynpi 0.11.0, commit 03469ae)

| Item | Location | Contract |
|---|---|---|
| `phrase_key(x, remove_apostrophes = TRUE)` | `R/normalize.R:94` | `normalize_string()` fold → `[^A-Z0-9 ]`→space → whitespace collapse → `NA` for empty/NA. Upper-case ASCII words, single spaces. Apostrophes deleted (curly/modifier/okina folded first). **NA in → NA out, never `""`.** |
| `compact_name_key()` | `R/normalize.R` | Squash contract: every non-letter deleted; additionally drops parenthesised alternate names. For join keys where word boundaries must not survive. |
| `normalize_string()` | `R/normalize.R` | Lower/upper fold + transliteration surface used by `normalize_name_columns`, `normalize_physician_names`. |
| Export | `NAMESPACE:42` | `export(phrase_key)` present. |
| Docs | `man/phrase_key.Rd` | Documented, `remove_apostrophes` argument covered. |
| Version | `DESCRIPTION` | `Version: 0.11.0`. No git tag ≥ v0.8.0 covers it — the approved pin is the commit SHA `03469aed868ea6af1e429b1da033915e49010dc7`, not a tag. |

## Downstream callers (midwifery)

| Caller | File:line | Delegates to | NA/empty contract | Version/export guard |
|---|---|---|---|---|
| `normalize_name()` | `R/build_amcb_state_licenses.R:52-61` | `mysterynpi::phrase_key(value)` | NA→NA (inherited) | `requireNamespace` only — **no export/version check** |
| `normalize_text()` | `amcb_license_bridge.R:113-122` | `mysterynpi::phrase_key(blank_to_na(x))` | blank→NA before key | `requireNamespace` only — **no export/version check** |
| `normalize_name()` (local, former-name path) | `expand_former_name_candidates.R:139-140` | `mysterynpi::compact_name_key(name_value)` | per upstream | install check at `:77` |
| `street_key()` | `build_worksite_setting_crosswalk.R:56-65` | `mysterynpi::phrase_key(clean(x))` | **adapts NA→`""`** so `paste()` separators survive (`:63-65`) | **`"phrase_key" %in% getNamespaceExports` check — strongest guard in repo** |
| `training_norm_school()` | `R/lib/training_institution.R:42-51` | `mysterynpi::phrase_key(y)` | NA→NA | guard at `:42` (message names the pin) |
| `normalize_string`, `normalize_name_columns`, `normalize_physician_names`, `sql_npi_name`, `needs_normalization`, `extract_first_initial` | `R/string_normalization.R:36-40` | direct aliases to `mysterynpi::` | per upstream | `requireNamespace` + `packageVersion >= 0.2.0` |
| `normalize_name_key()` | `R/string_normalization.R:46-48` | `gsub("\\s+"," ", mysterynpi::normalize_string(x))` — composition, not reimplementation | — | inherits shim guard |
| `match_nppes.R` name columns | `match_nppes.R:130-647` | `normalize_string()` via the shim | — | inherits shim guard |

## Non-phrase_key local normalizers (reviewed, out of contract scope)

| Function | File | Verdict |
|---|---|---|
| `county_key()` | `R/lib/work_site_topology.R:30-44` | Local `iconv(ASCII//TRANSLIT)` fold + domain rules (Saint→St, CT→connecticut, keeps "City"). **Different key contract** (geography, not person-name phrases) — not a phrase_key violation. Shares the iconv-fold drift-risk class; the macOS/glibc `ñ`→`~n`/`n` divergence is already handled in-code (`:31-33`). |
| `normalize_license()` | `R/build_amcb_state_licenses.R:65-72` | License-number squasher (`[^A-Z0-9]` deleted). Different domain; no apostrophe/phrase semantics. |
| `normalize_state()` variants | several | State-code canonicalizers; unrelated to phrase keys. |

## Migration status

The D15 drift (private copies that never folded accents — "José" keyed as "JOS E") is resolved: every person-name/phrase surface found delegates to `mysterynpi::phrase_key` or `compact_name_key`. `tests/test_org_apostrophe_normalization.R` O4b–O4f source-grep assertions prove no local punctuation pass survives in `training_institution.R`, `build_worksite_setting_crosswalk.R`, `extract_dac_midwives.R`-adjacent code, and `build_table1_midwives.R`.
