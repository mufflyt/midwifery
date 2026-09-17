# Data sources and purposes — methods draft

Draft prose for a manuscript "Data sources" subsection covering the six
sources below. Written in the project's existing methods voice (see
`midwife_persistence.qmd`, "Data sources and study population"), with
citation keys already added to `references.bib`
(`open_payments2024`, `medicare_partb_partd`, `state_bon`, `healthgrades`; `amcb2026`
and `nppes` already existed). Copy the paragraphs that apply into the target
`.qmd` and wire any stated counts through `mw_n()` / `mw_safe_stat()` rather
than leaving them as typed literals — this repository's build fails a render
that types a protected number directly into prose.

Two sources — American Midwifery Certification Board (AMCB) and the National
Plan and Provider Enumeration System (NPPES) — establish identity and are the
only sources `midwife_persistence.qmd` currently uses; nothing below should be
added to that manuscript unless its analysis actually draws on it. The other
four are corroborating/enrichment sources used elsewhere in this repository
(hospital-affiliation and organization-resolution work, board-verification
appendices, age calibration) and belong in whichever manuscript's methods
section actually reports on that analysis.

## AMCB — American Midwifery Certification Board public verification directory

The certification roster is the sampling frame: it is the sole certifying
body for this workforce, so linkage against it is a complete enumeration
rather than a survey sample. The directory supplies name, credential (CM or
CNM), certification number, status (ACTIVE/DECEASED/etc.), and certification
and expiration dates — no practice location at any level. It was scraped in
full (22,309 certificants: 183 CM, 22,126 CNM, reconciling to the directory's
own reported totals) via `scrape.py`, then linked to a provider identity by
`match_amcb_to_npi.R` and `reconcile_linkage.R` [@amcb2026].

## NPPES — National Plan and Provider Enumeration System (CMS)

NPPES is the linkage target: the historical dissemination files, one annual
snapshot per year from 2007 through 2025, supply provider identity (NPI),
taxonomy history, name history (including former/maiden names), and practice
address *with the year it was observed*. This is what turns an AMCB
certification record into a geolocatable person, and the annual-snapshot
structure is what allows a certificant to be matched under a name she no
longer holds. The full dissemination file (most recent monthly extract) and
the secondary-practice-location (`PL`) file supplement the historical panel
with current primary and secondary practice addresses [@nppes].

## Healthgrades.com

A corroborating identity- and address-recovery source used only for AMCB
certificants who matched **no** NPPES record at all — midwives who matched
NPPES already have an address, so their unresolved problem is geocoding, not
address discovery. Healthgrades profile pages embed schema.org JSON-LD blocks
carrying a structured street address and, separately, an NPI inside embedded
page script that is not displayed to the reader; the NPI is recovered by
regular expression and accepted only if it passes the Luhn checksum, which is
what makes this a matching source rather than merely an address source. No
access date was recorded for these scrapes; the scrape checkpoints are
timestamped August 2026 [@healthgrades].

## State Board of Nursing (BON) licensure and practice-address portals

Approximately 40 state board portals — Socrata open-data APIs for a subset of
states (Washington, Florida, New York, Texas, Illinois) and public HTML
verification lookups elsewhere — served two distinct purposes and should not
be conflated in text. First, license issue and renewal dates supported an
age-at-certification calibration for boards that publish a birth year or a
first-issue date (offset assumptions are stated per state; a board publishing
no birth year contributes no age rather than an inferred one). Second,
board-reported practice addresses corroborated NPPES-derived practice
location. Access dates were not recorded per portal [@state_bon].

## Open Payments — general payments and covered recipient profile supplement (CMS)

Used exclusively to recover recent practice addresses and candidate Type-2
(organizational) NPIs for employer/affiliation resolution — **never** to
characterize or report on payment behavior of any kind, and no
payment-amount or payment-category figure in this project rests on this
source. The program-year-2024 extract (`P06302026_06032026`) supplied both
the general-payments file and the covered-recipient profile supplement, keyed
to NPI [@open_payments2024].

## Medicare Physician & Other Practitioners (Part B) and Part D Prescribers (CMS)

Used to answer a single corroborating question for the ACTIVE, primary-linked
cohort: whether a midwife billed Medicare, one row per provider per year,
2013–2023. Because CMS suppresses any provider-year with fewer than 11
beneficiaries, absence from either file cannot be read as "billed zero" — it
means billed nothing *or* billed fewer than 11 beneficiaries, and the two are
indistinguishable in these data. Part B and Part D participation are reported
separately (they are not interchangeable), and the Part D `_standardized`
series is used in preference to duplicate raw tables present for 2022–2023
[@medicare_partb_partd].
