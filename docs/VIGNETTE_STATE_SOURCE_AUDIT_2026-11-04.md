# A Vignette: Ten Sources Disagree About Where Midwives Practice — and That Turns Out to Be the Finding

*A narrative companion to [`TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md`](TECHNICAL_APPENDIX_STATE_SOURCE_AUDIT_2026-11-03.md). Every number below is drawn from that appendix and the artifacts it cites; this piece exists to tell the story the tables don't, not to introduce new analysis.*

## The question nobody could answer cleanly

Ask "where does this midwife practice?" and ten different federal, state, and
commercial sources will each hand you an answer — NPPES, CMS's Doctors &
Clinicians file, PECOS, Open Payments, two hospital-affiliation routes, state
boards of nursing, CMS's National Downloadable Health directory, Healthgrades,
Doximity. None of them is a gold standard. Each is a self-report, a claims
byproduct, a licensing record, or a commercial scrape, built for a purpose
that has nothing to do with answering this particular question precisely.

The instinct, faced with ten imperfect witnesses, is to average them: have
the sources vote, report the majority answer, move on. This repository's own
prior audit makes clear why that instinct is wrong here — on the handful of
cases where Open Payments, Healthgrades, and Doximity could all be compared
directly, they agreed on **zero of five**. A majority vote across sources that
disagree that badly wouldn't surface the truth; it would manufacture a
consensus none of the underlying sources actually support. So this audit
never pools. It reports every pairwise disagreement as a finding in its own
right, and the payoff is a question the averaged version could never have
asked: *why* do they disagree?

## A twelve-year flat line, then one wobble

The most basic fact — does agreement with NPPES erode over time, the way a
reasonable prior would suggest as records age and go stale? — turns out to be
almost entirely wrong, and the way it's wrong is itself informative.

An earlier pass of this audit had DAC/Physician Compare at five scattered
vintages — 2013, 2014, 2015, 2016, then a nine-year jump to 2026 — and the
two endpoints looked like a steady decline. Filling in the missing years
(they were sitting, unused, in an already-mounted DuckDB file the whole time)
erased that story. DAC agreement with NPPES holds in a tight 91.8–95.1% band
for thirteen consecutive years, 2013 through 2025. No drift, no decay, just a
flat line — until 2026, which drops to 89.8%. One point can't tell you
whether that's the start of something or a single bad year; next year's pull
is the actual test. The lesson generalizes past this one source: a trend
built from five points can be an optical illusion that thirteen points
dissolve.

## The source that looked worst was being asked a different question

PECOS revalidation sits at 87.8–88.7% agreement with NPPES across six
straight years — consistently the lowest of the administrative sources, and
by enough of a margin that it reads, at first, like the weak link in the
chain. But that framing assumes NPPES is the right thing to compare against.
Pairwise — PECOS against every other source directly, not funneled through
NPPES as an anchor — PECOS agrees about as well as the other sources agree
with *each other*. Anchoring to NPPES made PECOS look like an outlier because
NPPES itself turned out not to be a neutral reference point; freed from that
anchor, PECOS isn't an outlier at all. The number that moved wasn't PECOS's
accuracy. It was the question being asked of it.

What the pairwise comparison surfaces instead is a different low point:
**CMS's own National Downloadable Health directory**. Among the 21 same-year
2026 pairs across the six current-snapshot sources, NDH disagrees most with
four separate counterparts — DAC, Doximity, Healthgrades, and PECOS, not just
NPPES. A source that disagrees with nearly everyone, rather than with one
specific counterpart, points at itself as the common denominator — exactly
the kind of signal that a single anchored comparison against NPPES would
never have revealed, because NDH was never being compared against the
sources it actually struggles to agree with.

## Most disagreement isn't noise. It's two correct answers at once.

The most consequential turn in this audit answers a question every prior
version of it could only shrug at: when ten imperfect sources disagree about
one midwife's practice state, is that noise, or is it two sources each
correctly describing a provider who genuinely practices in more than one
place?

The audit had never had a source that captures multi-state licensure
*directly* — until a second look at a file already being read for something
else. CMS's Open Payments Covered Recipient Profile Supplement — 1.69 million
rows, already mined for name and address fields — carries five columns of
licensed states per provider, entirely independent of every practice-location
source already in the audit. Matched against the cohort: 8,411 of 16,775
midwives (50.1%) have a profile at all, and of those, 2,865 — better than one
in three — are licensed in two or more states.

Cross that against the per-NPI consensus tiers already built from the other
nine sources, and the pattern is stark. Midwives licensed in exactly one
state are **92.4% unanimous** across sources, with only a 2.4% split rate —
about what you'd expect from ordinary data noise. Midwives licensed in two or
more states are **59.9% unanimous**, with a **22.1% split rate** — roughly
nine times higher. χ²(2, n = 8,312) = 1,353.1, p < 2.2×10⁻¹⁶. That is not a
subtle effect.

This doesn't prove any one specific disagreement is genuine multi-state
practice rather than a data error — it's a population-level association, not
a per-case adjudication. But it reframes the entire audit's central ambiguity.
Every earlier section of this work could gesture at "maybe some of this
disagreement is real multi-state practice" without being able to test it.
Now there's a direct answer: multi-state licensure is the dominant driver of
cross-source disagreement in this cohort, not an edge case. The sources
weren't all wrong about the same midwife. In nearly a quarter of split cases,
they were each right about a different place she practices.

## Disagreement, once it appears, mostly just... stays

The last piece asks whether a split, once it happens, is a blip that
resolves itself the following year or a durable feature of a given provider.
Tracking the 184 NPIs with NPPES, DAC, Open Payments, and PECOS all present
in every year from 2021 to 2025 — a small, demanding cohort, by design — the
dominant pattern is persistence: roughly 165–169 of those 184 stay unanimous
across every single year-to-year transition. A smaller, steady trickle moves
a handful of NPIs between tiers each year, without the churn accumulating
over time — consistent with real events (an address change, a new employer)
that one source picks up before the others catch up, rather than random
measurement noise working its way through the data.

## Where this leaves the audit

None of this resolves into a single clean number the way a pooled consensus
score would have. That's the point. Ten sources built for ten different
purposes were never going to converge on one practice-state value per
midwife, and forcing them to would have hidden exactly the structure that
turned out to matter: a flat multi-year baseline disturbed by one recent
year, an anchor effect that made an unremarkable source look like an outlier,
a genuinely discordant federal directory hiding in plain sight, and —
underneath a quarter century of disagreement that looked like noise — a
population of midwives who are, quite simply, licensed and practicing in
more than one state at once.

The multi-state-licensure flag now feeds directly into Table 1
(`build_table1_midwives.R`, see the technical appendix §5), gated behind the
same file-existence contract every other enrichment block uses, so a cohort
build missing the input refuses to publish rather than quietly omit the
category.
