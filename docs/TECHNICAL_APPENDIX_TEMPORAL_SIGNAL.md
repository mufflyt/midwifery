# Technical Appendix: The Temporal Signal, and Why It Is Switched Off

**Repository**: `midwifery`
**Primary code**: `amcb_temporal_separation()` in [`R/amcb_resolver.R`](../R/amcb_resolver.R),
[`analyze_temporal_plausibility.R`](../analyze_temporal_plausibility.R)
**Tests**: [`tests/test_temporal_separation.R`](../tests/test_temporal_separation.R)
**Decision**: [DECISIONS_CONTRACT.md](DECISIONS_CONTRACT.md) D17, `RULING: none`

---

## 1. What the matcher blocks on

Everything, exhaustively:

| | key | then filtered by |
|---|---|---|
| pool | midwifery + nursing taxonomy codes | — |
| `s1` | exact surname + exact given name | — |
| `s2` | exact surname + first initial | given names must differ (`s1` owns exact) |
| `s3` | exact given name | surname edit distance 1–2, surname ≥ 5 chars |
| `s5` | surname component | exact given name |

That is the whole of it. **No location** — the AMCB roster publishes none, at
any geographic level. **No date of birth.** **No temporal window of any kind**:
`certification_date` appears **zero times** in
[`match_amcb_to_npi.R`](../match_amcb_to_npi.R).

## 2. The axis that was available and unused

The roster carries `certification_date`. The provider panel carries a snapshot
year per NPI, so a first-appearance year is derivable. §7 of
[`TECHNICAL_APPENDIX_RECORD_LINKAGE.md`](TECHNICAL_APPENDIX_RECORD_LINKAGE.md)
already uses certification era analytically — pre-2006 certificants are
ascertained at 84.4% against 84.7% for 2006-or-later, three tenths of a point,
which is how the pre-NPPES era was ruled out as a matching failure.

So the comparison was possible all along. It had simply never been made against
individual candidates.

## 3. Why nobody could ask the question

`match_amcb_to_npi.R` has always written `linkage_candidate_audit.csv` — every
plausible pair, losers included, so that adding a candidate source can never
make a known candidate vanish. It declared:

```r
first_year = NA_integer_, last_year = NA_integer_
```

Declared, and left `NA` from the beginning. Someone reserved the columns for
exactly this and stopped. With them empty, *"would a temporal rule separate any
of the 3,044 tied records?"* could not be answered from any committed artifact
— the question could not even be posed without re-running the pipeline and
writing new code.

They are populated from the panel now, with `first_year_censored` beside them.

## 4. Two uses, deliberately separated

**Validation.** Among matches already *accepted*, how many pair a certificant
with an NPI first seen implausibly early relative to her certification? These
are candidate false positives the name rules had no way to see. This use
changes nothing and needs no ruling.

**Separation.** Among the tied, in how many pools does the signal leave exactly
one survivor? This is an *upper bound on what a tiebreak could recover*, not a
recommendation to apply one.

## 5. The grace period is not zero

An RN enumerates for an NPI years before she certifies as a midwife. That is
the normal career order, not an anomaly. A rule keyed on *any* lead would flag
most of the cohort. Only a **long** lead is informative, and the default grace
is **25 years** — deliberately generous, so that what it flags is flagged for a
reason.

## 6. First-seen is a bound, not a date

The panel opens in 2007; NPPES began enumerating in 2006. An NPI first seen in
the earliest snapshot **may have enumerated before the panel opens**, so any
lead computed against it is a bound and rules nothing out.

This is the convention
[`build_reassignment_panel.R`](../build_reassignment_panel.R) already states for
relationship spells — *"first_seen / last_seen are BOUNDS. A relationship first
seen in the earliest snapshot may have begun years before it"* — and it is
inherited here rather than reinvented.

## 7. The defect the tests caught

The first implementation of `amcb_temporal_separation()` reported this pool as
**separated**:

| candidate | first seen | assessable? | outcome |
|---|---|---|---|
| A | 2007, censored | **no** | survives — cannot be ruled out |
| B | 2010 | yes | ruled out on a long lead |

One survivor, so: separated, promote A.

**That is separation by ignorance.** A survived only because nothing is known
about it; B was ruled out on real evidence. The rule promoted the candidate it
could not assess over the one it could — which is precisely how the middle-name
veto manufactured 218 unflagged matches (see
[`TECHNICAL_APPENDIX_RECORD_LINKAGE.md`](TECHNICAL_APPENDIX_RECORD_LINKAGE.md)
and the middle-name figure).

A pool now counts as separated only when its lone survivor was **actually
assessed**, and `separation_blocked_by_censoring` reports the difference. Tests
T3 and T5 exist to keep it out, and the test file is wired into CI even though
the mechanism is off — the mechanism being off does not make its semantics
unimportant, it makes them the only thing there is to get right.

## 8. Separating some pools empties others

Ruling out every candidate in a pool moves a record from `ambiguous_tied_names`
to something a reader will meet as **"no candidate"** — indistinguishable from
absence from the registry.

`analyze_temporal_plausibility.R` therefore prints emptied pools **above** the
separation count:

```
tied pools tested            N
WOULD separate               N  (N% of tied)
blocked by censoring         N
every candidate ruled out    N  <- would LOSE these, not gain them
```

Net recovery is separations **minus** emptied pools, and the sign of that is
not known in advance. It is the entire decision.

## 9. Why it is off

The resolver's stated rule, from [`R/amcb_resolver.R`](../R/amcb_resolver.R):

> *Several candidates at the strongest class means they are indistinguishable on
> the evidence held. Taxonomy must NOT break that tie: it says nothing about
> WHICH person the name refers to, only what the NPI does for a living.*

A first-seen year is **closer** to identity evidence than taxonomy is — an NPI
that did not exist until long after a certificant qualified is weak evidence
against that pairing. But "closer" is not "settled", and switching it on
converts 3,044 reported quarantines into published matches. That is a ruling,
not a refactor, and it is recorded as **D17** rather than made.

## 10. Running it

```
Rscript match_amcb_to_npi.R                        # repopulates first_year
Rscript analyze_temporal_plausibility.R --grace=25
```

Outputs: `artifacts/temporal_plausibility_summary.csv` and
`artifacts/temporal_separation_by_pool.csv` (aggregate, publishable);
`qa/temporal_implausible_accepted.csv` (person-level, gitignored).

Both scripts are declared in `REBUILD_ORDER`.
`analyze_temporal_plausibility.R` also reads `midwife_panel.csv`, so a rebuild
that has not refreshed the panel compares a current crosswalk against a stale
first-seen year — the [D10 vintage skew](TECHNICAL_APPENDIX_COHORT_VINTAGE.md)
one layer down. It prints the panel floor it used for exactly that reason.
