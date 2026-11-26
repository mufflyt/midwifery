# Mutation-detection report — phrase_key migration

Audit date: 2026-11-25. Question: can the midwifery suite detect (a) a local reimplementation of phrase normalization, and (b) adversarial name/phrase inputs that cause false-positive or false-negative matches?

## Existing detection machinery (verified green locally, mysterynpi 0.11.0 installed)

| Suite | What it proves | Result |
|---|---|---|
| `tests/test_org_apostrophe_normalization.R` | O4b–O4f **source-grep assertions**: `training_norm_school`, `street_key`, `extract_dac_midwives` normalization, `norm_institution_name` must contain `mysterynpi::phrase_key` and must NOT retain a local punctuation pass; duplicate `.norm_school` definition must be gone | PASS (0 failures) |
| `tests/test_amcb_license_bridge.R` | Delegation comment contract; umlaut fold via phrase_key; license-key collision handling | ALL PASS |
| `tests/test_expand_former_name_candidates.R` | Former-name path uses `compact_name_key`; candidate blocks distinguish current vs former; rescues never overwrite matches | ALL PASS |
| `tests/test_amcb_name_normalization.R` | Parser edge cases: NA in→NA out, empty string safe, blanks held out | PASS (0 failures) |
| `tests/test_amcb_name_keys_saboteur.R` | Saboteur harness for `R/amcb_name_keys.R` helpers (coalesce, key construction) | PASS (0 failures) |

## Adversarial input coverage map

| Variation | Covered by | Mechanism |
|---|---|---|
| Straight vs curly apostrophes (`'` `’` `ʼ` `ʻ`) | mysterynpi `phrase_key` fold + `test_org_apostrophe_normalization.R` org-name cases; `test_amcb_license_bridge.R` umlaut/apostrophe cases | upstream fold deletes apostrophes after Unicode normalization |
| Punctuation retained vs removed | O4b–O4f delegation assertions + phrase_key `[^A-Z0-9 ]`→space pass | contract: punctuation becomes separator, never survives in key |
| Parenthetical alternate names | `compact_name_key` (drops parentheticals) via `expand_former_name_candidates.R`; `split_former_surnames()` removes NEE/FORMERLY/MAIDEN markers first | two-stage: markers stripped, then squash key |
| Hyphenated clinician names | phrase_key: `-`→space, so "Smith-Jones" → `SMITH JONES` (word boundary preserved); `compact_name_key` → `SMITHJONES` | **intentional divergence** — phrase keys keep boundaries, compact keys don't; callers chose per join semantics |
| Whitespace differences | `gsub("\\s+"," ",trimws())` in phrase_key; `normalize_name_key` adds collapse over `normalize_string` | covered |
| Unicode normalization (accents, modifier letters) | upstream `normalize_string` fold; verified "Müller"→MUELLER parity claim in `expand_former_name_candidates.R:135-138` | covered upstream; midwifery asserts delegation, not re-fold |
| Missing values | phrase_key: NA→NA never `""`; `blank_to_na()` pre-pass in `normalize_text`; `street_key` deliberately adapts NA→`""` for `paste()` | covered, with one documented contract adaptation |
| Former names | `expand_former_name_candidates.R` + `test_expand_former_name_candidates.R` | covered |
| Distinct names that must NOT collapse | license-collision tests (`test_amcb_license_bridge.R`: "license key mapping to two NPIs -> not accepted"); saboteur suite | covered at the identity-decision layer, not the string layer |

## Gaps observed (reported, not fixed — no scientific change authorized)

1. **No midwifery-side property test asserting `normalize_name(x) == mysterynpi::phrase_key(x)` elementwise.** Delegation is proven by source-grep, not by behavioural equivalence. A future edit could wrap phrase_key in a way that changes semantics while keeping the call. Low risk (the wrapper is one line), but a 10-line property test would close it.
2. **`normalize_name()`/`normalize_text()` guards check `requireNamespace` only** — under a 0.9–0.10 install the failure is a missing-export error at call time, not a guard message. `street_key()` shows the stronger pattern.
3. **`county_key()`** retains a private `iconv` fold. Correct for its domain contract, but it is the only remaining place where a midwifery pipeline folds accents outside mysterynpi; if county matching ever feeds a name join it would reintroduce the D15 drift class.

## Mutation-detection verdict

The migration is **detectable-and-detected**: reintroducing a local punctuation pass or dropping the `mysterynpi::` call fails O4b–O4f immediately. Adversarial name inputs are handled by the upstream fold; midwifery's contribution is delegation assertions plus identity-layer collision tests. No false-positive/false-negative matching change was introduced by the migration — all inspected callers preserve their prior join semantics (phrase_key where boundaries matter, compact_name_key where they must not).
