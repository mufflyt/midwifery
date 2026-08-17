# Technical Appendix: Given-Name Matching Modes

**Status:** decision frozen. No production code or artifact was changed to produce it.
**Date:** 2026-08-16
**Scope:** how two person-name records are judged to describe the same human, and why that judgement depends on the *structure of the source*, not on a single global rule.

---

## 1. The decision

Two explicit modes. The caller states which one it wants; the library never infers it.

| Source A | Source B | Name structure | Mode |
|---|---|---|---|
| AMCB structured fields | NPPES structured fields | reliable field position | `positional_ie` |
| board roster | structured registry | reliable field position | `positional_ie` |
| repository author string | AMCB structured fields | unreliable ordering / credentials | `any_token` + positional evidence |
| free-text citation | structured registry | unreliable | `any_token` + downstream corroboration |

> **Mode selection is a property of the source contract, not of the individual name. Callers must select it explicitly.**

A library that sniffs "does this look like free text?" and silently picks a matcher has embedded an unauditable scientific decision in a heuristic. The caller knows whether it holds structured NPPES columns or a scraped author byline. It must say so.

Under `any_token`, `given_match_position` (`both_first` / `one_first` / `both_middle`) must be carried forward as evidence, and **`both_middle` alone must never be promoted to identification.**

---

## 2. `positional_ie` defined

A candidate pair is admitted when the surname is compatible **and** the given names satisfy either clause:

1. **Positional agreement.** The parsed leading given names are equal after canonical normalization, or equivalent under the nickname dictionary (`Beth` ≡ `Elizabeth`). Nickname equivalence is evaluated on full tokens only; it never applies to an initial.
2. **Initial expansion.** One side's parsed leading given name is a single alphabetic character *I*, and the other side's parsed leading given name is a full token of ≥ 2 characters beginning with *I*.

**Definitions and invariants**

- **Initial** = exactly one alphabetic character after normalization, with any trailing period removed. `S.` and `S` are initials; `DM` is not.
- **Comparison operates on the PARSED leading given name, not on the token set.** `amcb_given_tokens()` drops tokens shorter than 2 characters, so an initial never enters the token set at all. In `Dowdle, S. Addreina` the leading *token* is `ADDREINA` — the middle name. Initial expansion is only reachable before tokenisation.
- **An initial alone must never identify a person.** Clause 2 requires a full token on the other side and a surname match; two initials on both sides (`S.` vs `S.`) do **not** admit a pair. An initial is corroboration, never identification.
- **Initial expansion may generate a candidate**, not merely rescore one — otherwise the two recoveries in §5b are unreachable, since positional agreement never held for them.
- **Missing given names.** If either parsed leading given name is `NA` or empty, neither clause can be satisfied and no candidate is generated. Absence is never evidence.

**Why `positional_ie` supersedes plain `positional`**

- identical observed permutation collision proxy in this experiment (13%; 106 control certificants in both arms);
- two additional adjudicated true positives (§5b);
- no adjudicated loss among the cases that differed.

This is **not** a claim of equal precision. Only the differing cases were adjudicated.

---

## 3. Experiment definition (frozen)

Sidecar experiment. `link_theses_to_amcb.R` and `artifacts/amcb_training_institution.csv` were **not** modified; a copy of the script was patched with a mode switch and run three times to scratch outputs.

Everything other than candidate generation was held identical across arms: parsing, surname rules, rarity corroboration, ambiguity handling, evidence classification, temporal window, and the permutation control. The mode filter is applied *after* `given_match_position` is computed, so the classification is identical in every arm.

| parameter | value |
|---|---|
| author corpus | `artifacts/acme_dnp_authors.csv` — 35,128 rows, 35,038 with a non-missing author string |
| AMCB roster | `midwives.csv` — 22,309 certificants |
| linkage frame | `artifacts/amcb_npi_linkage_FROZEN.csv` — 22,309 rows |
| RNG seed (permutation control) | `20260810` |
| control construction | one permutation index applied to **both** `given_tokens` and `parsed_first`, so the control cannot gain an unshuffled initial-expansion channel |

**Input hashes (sha256)**

| input | bytes | rows | sha256 |
|---|---|---|---|
| `artifacts/acme_dnp_authors.csv` | 9,291,442 | 35,128 | `82d4391c4cebcc1a754f6f55152279282a0d6f16bfa9e2ca94d4c93ca5fcba94` |
| `midwives.csv` | 1,945,510 | 22,309 | `fe035788018f076db16f8dbe9c1b484f062d5ee3af8f6106547ed1886e127d11` |
| `artifacts/amcb_npi_linkage_FROZEN.csv` | 10,020,816 | 22,309 | `dbcc76f420ac9be850efcc8aabc1523772cbcccea259783db88a5099d3a2209b` |

**Collision proxy formula**

```
collision_proxy = 100 * n_distinct(certificants matched in the PERMUTED arm)
                      / n_distinct(certificants matched in the REAL arm)
```

> **13% and 19% are permutation collision proxies. They are NOT observed
> false-positive rates, sensitivity, specificity, PPV, or accuracy.**
> They estimate how many matches survive when given names are shuffled against
> surnames within the same harvest. No adjudicated truth set exists for these
> links. Do not restate them as precision or error rate.

**Evidence classes** (as defined in `link_theses_to_amcb.R`)

| class | name | definition |
|---|---|---|
| 1 | `collection_specific` | collection is midwifery-specific; membership is the evidence (e.g. Frontier). Accepted regardless of temporal gap |
| 2 | `generic_concordant` | generic DNP collection **and** gap inside the institution's fitted window, or midwifery text present |
| 3 | `generic_discordant` | generic collection, name match only. Candidate, not accepted |
| 4 | `ambiguous` | more than one AMCB certificant matches the same project |

---

## 4. Results

| mode | pairs | authors | certificants | control certificants | collision proxy | c1 | c2 | c3 | c4 |
|---|---|---|---|---|---|---|---|---|---|
| `any_token` | 941 | 802 | 876 | 165 | 19% | 653 | 100 | 23 | 165 |
| `positional` | 833 | 755 | 790 | 106 | 13% | 645 | 106 | 0 | 82 |
| `positional_ie` | 835 | 757 | 792 | 106 | 13% | 647 | 106 | 0 | 82 |

**Difference, `any_token` minus `positional_ie`:** 103 artifact rows. Retained by both: 838. `positional_ie`-only: 0.

| category | n | interpretation |
|---|---|---|
| `both_middle` | 23 | already demoted to class 3 by design; losing them costs little |
| class-4 ambiguity | 67 | ambiguity being *resolved*, not evidence discarded |
| **class-1 losses** | **13** | genuine high-evidence links only `any_token` can reach |

A further **17** pairs changed class rather than disappearing — all class 4 → class 1 (9) or class 2 (8), because removing the rival candidate resolved the ambiguity. Class 4 fell 165 → 82.

**Machine-readable sidecar:** `differing_pairs_any_token_only.csv` (scratch, not committed — it is person-level). It carries **119 rows** for the 103 artifact rows, because a single (certificant, institution) key can rest on more than one underlying author-token pair. Pair-level breakdown: `one_first` 13/11/27 and `both_middle` 0/12/56 across classes 1/3/4. Do not quote the pair-level counts as the artifact-level decomposition; they measure different units.

---

## 5. Case evidence

Each case is labelled by provenance so an illustrative example cannot later be mistaken for cohort evidence.

- **`observed`** — appeared in the experiment output.
- **`adjudicated observed`** — appeared in the output and was inspected by hand.
- **`synthetic/adversarial`** — constructed to exercise a rule; **not** drawn from the cohort.

### 5a. `any_token` must survive — preferred middle name — *adjudicated observed*

| repository author | AMCB certificant |
|---|---|
| `Lott, Marian Vanita` | `Vanita Lott` |
| `Williams, Roselind Renee` | `Reneé Ann Williams` |
| `Hayes, Renee Christine` | `Christine Anne Hayes` |
| `Johnson, Zandra Kay` | `Kay L Johnson` |

People who publish under their middle name. No initial is involved, so no positional rule — with or without initial expansion — can reach them.

### 5b. `positional_ie` must recover — expanded initial — *adjudicated observed*

| repository author | AMCB certificant | repo leading | AMCB leading | class |
|---|---|---|---|---|
| `Dowdle, S. Addreina` | `Shaquinda Addreina Dowdle` | `S` | `SHAQUINDA` | 1 |
| `Rumsey, C. Emerson` | `Chad Emerson Rumsey` | `C` | `CHAD` | 1 |

Recovered at zero measured change to the collision proxy.

### 5c. `positional_ie` must reject — first ↔ middle collision — *adjudicated observed*

| repository author | AMCB certificant | shared token |
|---|---|---|
| `Anderson, Elizabeth` | `Annagrace Elizabeth Anderson` | `ELIZABETH` |
| `Anderson, Elizabeth` | `Rondi Elizabeth Anderson` | `ELIZABETH` |
| `Hale, Michelle` | `Connie Michelle Hale` | `MICHELLE` |
| `Jones, Mary K.` | `Angela Mary Jones` | `MARY` |
| `Borders, Noelle` | `Aleda Noelle Borders` | `NOELLE` |

The repository author's *first* name is the certificant's *middle* name. The first two rows are one author string matching two different certificants — exactly the ambiguity `positional_ie` resolves.

### 5d. Reordered author string — *synthetic/adversarial*

`Williams, W. Jon` ↔ `Jon W Williams`

This is the justification written into `link_theses_to_amcb.R` for token-set matching. **It was NOT among the 50 observed `one_first` cases in this experiment.** It remains a valid adversarial fixture — reordering is a genuine risk in author strings — but it is an *illustrative failure mode*, not measured cohort evidence, and the production comment should be reworded to say so. The observed rescues were expanded initials (5b) and preferred middle names (5a), which are different mechanisms.

### 5e. Parse damage, not match failure — *adjudicated observed*

`Loomis, DM, CRNP, CNM, Heidi` ↔ `Heidi Marie Loomis`. **Matched in production**
under `any_token`; the damage costs a misclassified position (`one_first` rather
than `both_first`), not the match. It is reachable only under `positional_ie`
once the cleaner is fixed. See §6.

---

## 6. Loomis: two distinct defects, different owners

**These are two separate bugs and must not be combined into one.**

| layer | input | first | middle | last |
|---|---|---|---|---|
| 1. canonical `parse_physician_name_enhanced()` | **raw** | `Loomis` | — | **NA** (suffix = `DM, CRNP, CNM, Heidi`) |
| 2. `amcb_strip_name_noise()` | raw | → `Loomis DM Heidi` | | |
| 3. canonical parser | stripped | `Loomis` | `DM` | `Heidi` |
| 4. full `amcb_parse_person()` | raw | **`DM`** | `HEIDI` | `LOOMIS` |
| control | `Loomis, Heidi` | `HEIDI` | — | `LOOMIS` |

### Defect 1 — causal, owned by `midwifery`

The parse damage is caused by the **midwifery preprocessing path**. `AMCB_NAME_NOISE` lists `MD`, `DO`, `DNP`, `DNSC`, `DNS`, `CRNP`, `CNM` — but **not `DM`**. The stripper removes `CRNP` and `CNM`, leaves `DM`, and the AMCB-specific comma reversal then makes `DM` the leading given name.

#### Measured impact — smaller than first stated

**Correction.** An earlier draft of this appendix described Loomis as a lost
class-1 thesis match in production. **It is not lost in production.** The thesis
pipeline runs `any_token`, and `amcb_given_tokens()` yields `{DM, HEIDI}` for the
damaged parse, so the join still finds `HEIDI` and the match is made. What the
defect actually costs today is a **misclassified match position**: the pair reads
`one_first` when it should read `both_first`.

Counterfactual, run against the frozen inputs of §3 with a contextual DM rule
(drop `DM` only when an immediately adjacent token is itself a known credential;
token-based, never substring):

| arm | rows | certificants | authors | control | collision proxy | c1 | c2 | c4 |
|---|---|---|---|---|---|---|---|---|
| `any_token` (production mode) | 941 | 876 | — | 165 | 19% | 653 | 100 | 165 |
| `any_token` + contextual DM | 941 | 876 | — | 165 | 19% | 653 | 100 | 165 |
| `positional_ie` | 835 | 792 | 757 | 106 | 13% | 647 | 106 | 82 |
| `positional_ie` + contextual DM | **836** | **793** | **758** | 106 | 13% | **648** | 106 | 82 |

Under the production mode the fix changes **nothing** — 0 gained, 0 lost, 0 class
changes. Under `positional_ie` it gains exactly **1** class-1 linkage
(certificant `8108`, Thomas Jefferson University), loses none, and leaves the
collision proxy and ambiguity count unchanged. Loomis then classifies
`both_first` with `.first_repo == .first_amcb == HEIDI`.

So the defect becomes a genuinely lost match only **if** the thesis path ever
switches to `positional_ie`. That lowers its urgency: it is a correctness and
classification-quality issue today, not a recall loss.

### Defect 2 — independent, owned by `isochrones`

`isochrones::parse_physician_name_enhanced()` independently parses the untouched credential-heavy raw string poorly: it returns no last name and collapses `DM, CRNP, CNM, Heidi` into `suffix`.

**This upstream weakness did NOT cause this production loss**, because the thesis pipeline never supplies that raw representation to the canonical parser — it always passes the output of layer 2. It deserves its own fixture and its own evidence in a later upstream PR. It must not be cited as the cause of the observed miss.

### Follow-up on `DM` — separate issue, not part of this decision

Do **not** add `DM` to `AMCB_NAME_NOISE` on the strength of one case. Corpus survey performed:

| population | standalone `DM` tokens | classification |
|---|---|---|
| `acme_dnp_authors.csv` (35,038 author strings) | 5 distinct strings | **5/5 credential-adjacent**, 0 apparent initials |
| `midwives.csv` name fields (22,309 certificants) | **0** | — |

Observed occurrences: `Loomis, DM, CRNP, CNM, Heidi M.` · `Loomis, DM, CRNP. CNM, Heidi M.` · `Macon, DM, CNM, Sandra` · `Starkey, DM, APRN, CNM, Rebecca R.` · `Rosenbaum, DM, CNM, MSS, Allison`.

In this corpus `DM` is unambiguously a credential, and it never appears as a name token on the roster side. That supports a fix — but a **context-aware** one (a `DM` adjacent to other credential tokens) is safer than a blanket token deletion, because `DM` remains plausible initials in corpora not yet examined.

The contextual rule was prototyped and measured (see §6, *Measured impact*). Per-string result:

| raw | parsed, current cleaner | parsed, contextual DM |
|---|---|---|
| `Loomis, DM, CRNP, CNM, Heidi M.` | `DM \| HEIDI M \| LOOMIS` | `HEIDI \| M \| LOOMIS` ✅ |
| `Loomis, DM, CRNP. CNM, Heidi M.` | `DM \| HEIDI M \| LOOMIS` | `HEIDI \| M \| LOOMIS` ✅ |
| `Macon, DM, CNM, Sandra` | `DM \| SANDRA \| MACON` | `SANDRA \| NA \| MACON` ✅ |
| `Starkey, DM, APRN, CNM, Rebecca R.` | `DM \| REBECCA R \| STARKEY` | `REBECCA \| R \| STARKEY` ✅ |
| `Rosenbaum, DM, CNM, MSS, Allison` | `DM \| MSS ALLISON \| ROSENBAUM` | `MSS \| ALLISON \| ROSENBAUM` ❌ |

Four of five are corrected. **`Rosenbaum` is not**, for an unrelated reason: `MSS` is absent from `AMCB_NAME_NOISE` and becomes the leading given name once `DM` is removed. That is a separate gap in the credential list, not a failure of the contextual rule. The trailing-period variant (`CRNP.`) is already handled, because the existing code strips periods before the membership test.

Tracked as a separate `midwifery` follow-up, now with a measured blast radius of **zero rows under the production mode** and **+1 class-1 linkage under `positional_ie`**. It is not part of the matching-mode decision, and its priority is correspondingly low.

---

## 7. Specification for the upstream primitives (isochrones PR 2)

To be opened **after** isochrones #547 merges, branched from the resulting `main`.

```r
name_surname_components()
name_given_tokens()
name_leading_given()
names_have_compatible_surname()
names_have_compatible_given(..., mode = c("positional_ie", "any_token"))
```

**Requirements**

1. **Normalize internally** through the canonical normalization layer. A caller must not be able to recreate the mixed-case failure by passing raw input; the case contract cannot live in a comment.
2. **`NA` and empty are never evidence.** A blank middle name is a recording gap, not a claim that the person has none. `nzchar(NA)` is `TRUE` and must never be the test.
3. **No substring surname containment.** `Anderson` must not match `Sanderson`.
4. **Compound and hyphenated surnames** compare by component set: `Nelson` ⊆ `Nelson-Becker`, `Dyer` ⊆ `Dyer Hill`.
5. **Full-token middle agreement/conflict**, not initial-only. `Susan Marie` vs `Susan Magee` is a conflict.
6. **Initials never independently identify.** See §2.
7. **Mode is explicit at the call site.** No context-dependent automatic selection.

**Fixtures required**, each labelled with its provenance:

- ordered AMCB↔NPPES middle-name collision that must be rejected — *observed*, §5c
- `Williams, W. Jon` ↔ `Jon W Williams` under `any_token` — *synthetic/adversarial*, §5d
- preferred-middle-name class-1 examples — *adjudicated observed*, §5a
- expanded-initial recoveries — *adjudicated observed*, §5b
- cases removed as `both_middle` — *observed*, 23 rows in the sidecar
- cases moved out of ambiguity by `positional_ie` — *observed*, the 17 class-4 → class-1/2
- mixed-case input behaving identically to uppercase
- `Sanderson`/`Anderson`, `LaRodé`/`Larode`, `Erickson-Owens`/`Ericksonowens`, apostrophes

---

## 8. What was deliberately not done

- No production matcher changed.
- No tracked artifact regenerated; `artifacts/amcb_training_institution.csv` is untouched.
- `amcb_person_matches()` not modified — it has **zero production callers** (tests only), so changing it cannot alter any historical NPI assignment.
- `amcb_given_tokens()` not modified — its single production caller (`link_theses_to_amcb.R`) feeds it output from `amcb_parse_person()`, which is already normalized, so the mixed-case failure is not live there.
- `DM` not added to `AMCB_NAME_NOISE`; deferred to a separate, evidence-backed follow-up.
