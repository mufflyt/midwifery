# Materials and Methods — Recovering training institution from open repository metadata

*Draft methods subsection. Numbers current as of 2026-08-10.*

## Rationale

Practice location for certified nurse-midwives (CNMs) is recoverable from NPPES
once an identity linkage exists, but **training institution is not**. The CMS
Doctors and Clinicians (DAC) national downloadable file carries a midwifery
school name for only **14.3%** of the cohort, and the American Midwifery
Certification Board (AMCB) directory publishes none. We therefore sought an
external source in which the training institution is *structural* rather than
inferred.

Student-authored Doctor of Nursing Practice (DNP) projects, capstones and
theses satisfy this requirement. Such a work names its author and is deposited
in the institutional repository of the degree-granting university, so the
institution is determined by **which repository holds the record**, not by
parsing a free-text affiliation string. This distinguishes the source from
bibliographic databases, where affiliation is prose attached to a publication
and may reflect employment at time of writing rather than training.

## Data sources and protocols

Institutional repositories were queried directly rather than through an
aggregator, so that the repository of origin — and therefore the institution —
is unambiguous. Two protocols were required:

**Open Archives Initiative Protocol for Metadata Harvesting (OAI-PMH).** A
lightweight HTTP protocol exposing a repository's metadata catalogue as XML.
We used three verbs: `Identify` (endpoint liveness and repository name),
`ListSets` (enumerate collections), and `ListRecords` (retrieve records, paged
via `resumptionToken`). All compliant repositories expose unqualified Dublin
Core (`oai_dc`), from which we extracted `creator`, `title`, `date`, `type` and
`identifier`. OAI-PMH is implemented by the two dominant repository platforms,
bepress Digital Commons and DSpace.

**CONTENTdm (OCLC) web services.** Frontier Nursing University — the largest
nurse-midwifery program in the United States — does not run Digital Commons or
DSpace and exposes no usable OAI-PMH endpoint. Its repository runs CONTENTdm,
queried through the `dmwebservices` JSON API (`dmGetCollectionList`, `dmQuery`).
Because this institution contributes the majority of records, protocol
heterogeneity is not an implementation detail but a determinant of coverage: a
harvester supporting only OAI-PMH misses the single most productive source.

## Collection targeting

Sweeping an entire repository and filtering by keyword is ineffective at this
scale. Large repositories contain hundreds of thousands of records, of which
midwifery degree works are a vanishing fraction; a bounded sweep returns
essentially nothing, and an unbounded sweep is disproportionate to the yield.

We therefore **target collections rather than sweep repositories**. Collections
returned by `ListSets` (OAI-PMH) or `dmGetCollectionList` (CONTENTdm) are
classified by name into:

1. **Midwifery-specific** — the collection name or identifier matches
   `midwif|nurse[-\s]?midwi|CNM`. Membership is treated as sufficient evidence
   and **no further keyword filter is applied to its records**, because a
   midwifery thesis need not repeat the word "midwifery" in its title.
2. **Nursing degree-work** — the name matches nursing *and* a degree-work term
   (`ETD`, thesis, dissertation, doctoral, DNP, capstone). Midwifery theses are
   frequently deposited in a general nursing ETD collection, so these are
   harvested and **then** filtered on record text.
3. **Neither** — not harvested.

Where no qualifying collection exists, a bounded page sweep is used as a
fallback and is recorded as such in the output, because a keyword-filtered
sweep is weak evidence of absence rather than evidence of absence.

Every record carries an `evidence` field recording how it qualified
(`collection_is_midwifery` versus `keyword_match_in_*`), so that the weaker
basis remains visible to downstream analysis rather than being flattened into
an undifferentiated count.

## Record processing

Author strings are stored inconsistently across platforms (`Last, First M` in
CONTENTdm and bepress; `First M Last` elsewhere) and are split accordingly.
Names are normalised with the project's canonical normaliser, which applies
Unicode NFC composition, German romanisation and Latin-ASCII transliteration
before case folding, so that accented forms match their ASCII spellings.
Records are de-duplicated on (identifier, author).

## Linkage to the certification roster

Harvested authors were matched to the AMCB roster on exact normalised first and
last name. **This linkage is name-based and unanchored**: Dublin Core provides
no NPI, ORCID or credential, so no registry identifier is available to confirm
a match.

To quantify the resulting false-positive burden we used a **permutation
control**: author first names were randomly shuffled against surnames within
the harvested set and the match was repeated. Any matches surviving this
procedure arise from name collision rather than identification.

## Results of the pilot harvest

| Source | Records | Notes |
|---|---:|---|
| Frontier Nursing University (CONTENTdm) | 1,986 student-authored | DNP Projects (1,864) + Student Publications (122), 2009–2026 |
| 12 OAI-PMH endpoints, combined | 306 | only 6 classified as degree works |

Of 20 institutions with ACNM-accredited programs, **12 exposed a live endpoint**
and 8 did not (Frontier via CONTENTdm; Vanderbilt, Emory, OHSU, Rutgers,
Colorado, Georgia State and UMass returned DNS failure, 404 or malformed XML).

Matching Frontier's student-authored records to the AMCB roster identified
**555 certificants** with a documented training institution. The permutation
control yielded a **6.7%** false-positive proxy. Of the 555, **482 (86.8%)**
carried an NPI in the identity crosswalk.

For comparison, an equivalent author-name search of PubMed was evaluated and
rejected: querying `Last F[Author]` returned at least one record for 50% of
sampled midwives, but the same query with a **deliberately incorrect** first
initial returned records for 42% — a separation of 8 percentage points.
Restricting to the full-author-name field improved this only to 13% versus 8%.
PubMed author-name search therefore does not identify individuals in this
population at usable precision.

## Limitations

**Coverage is partial and non-random.** 555 of 22,309 certificants (2.5%) were
identified, overwhelmingly from a single institution. Institutions without an
open repository, or whose repository is not machine-readable, are absent
entirely; any distribution of training institutions computed from these data
would be biased toward institutions that publish student work openly.

**Only degree-seeking authorship is evidence of training.** Faculty and staff
publication collections were excluded, since a faculty publication indicates
employment rather than the author's own training.

**Identity is not resolved.** Matching is on name alone, with a measured ~6.7%
collision rate, and same-named students within one institution are not
disambiguated. These records should be treated as candidate identifications
pending review, not as confirmed assignments.

**Repository coverage is a moving target.** Endpoints verified live on
2026-08-10 may change; the harvester's registry retains failed endpoints
explicitly so that coverage gaps remain auditable rather than disappearing
from the source list.

## Software

`harvest_dnp_theses.py` (Python standard library only, consistent with this
project's convention for its Python stages). Supports `--probe` for endpoint
verification, per-institution selection, and configurable page bounds. Output:
`artifacts/dnp_theses_metadata.csv`.
