# AccessMRF / Transparency in Coverage extraction

Two projects share this directory. They have different evidentiary standards
and must not be mixed.

## Project A — NPI ↔ billing organization

Viable now. Needs no market-completeness assumption.

The unit of evidence is: *this NPI appears in this payer's MRF provider
groups, tied to this billing identifier.*

    npi | tin_type | tin_value | business_name | payer | source_month | source_file

**Organization analyses MUST filter to `tin_type == "ein"`.** Rows with
`tin_type == "npi"` are preserved but are never an organization — see the
defect note below.

## Project B — commercial insurance access

Experimental, and currently blocked on semantics.

The endpoint is **`CNM observed in payer MRF provider groups`**. It is *not*
network participation, and absence is *not* evidence of non-participation.
Market-share figures in `colorado_payer_market.csv` are descriptive context
only; they do not license inference about midwives we did not observe.

Unresolved: a Kaiser file labelled Colorado contains providers from every
Kaiser region (321 Colorado midwives, but also 237 California, 143 Oregon,
89 Maryland). Until we know what an MRF appearance represents, it cannot be
read as "a member of this plan can see this midwife."

---

# SUPERSEDED — DO NOT CITE

## The `tin_type` defect

The four-file pilot artifacts below were built **before** `tin.type` was
recorded. The TiC schema allows `tin.type` to be `"ein"` or `"npi"`, and payers
use both heavily — 83% of Kaiser's Colorado provider groups are `type = "npi"`,
where the value is the provider's own NPI used as a self-billing identifier,
not an employer EIN.

Collapsing both into one `tin` column makes any count of "distinct TINs"
meaningless as an organization count, and fills the size distribution with
artefactual one-NPI entries.

**Retracted figure:** the "90.5% of TINs have a single NPI" result reported
from the four-file pilot is an artifact of this defect, not a finding about
practice structure. It must not appear in notes, manuscripts, or any
downstream artifact. Corrected Kaiser Colorado figures, after the fix:

    tin_type   rows        distinct ids   distinct npis
    ein        1,474,856         22,264         121,436
    npi        1,037,644        348,622         348,622   (1 NPI each, by construction)

    406  Colorado CNMs in the canonical cohort
    321  appear somewhere in Kaiser provider references
    289  have at least one EIN relationship
     77  distinct EIN organizations hold them

Affected files, kept only as provenance for how the defect was found:

- `npi_tin_crosswalk.csv` — no `tin_type` column; EIN and NPI spaces conflated
- `mrf_network_panel.csv` — `npi_count_under_tin` and the size distribution
  derived from it are invalid
- `pilot_build_network_panel.py` — the code that produced both
- `pilot_extract_4file.py` — the original four-file extractor

Current extraction is `../../accessmrf_03_pull_provider_refs.py`, which records
`tin_type` on every row and pads the EIN and NPI identifier spaces separately.

## A second caveat on `business_name`

Some `tin_type == "ein"` rows carry payer names rather than provider
organizations — `DENTAQUEST CO`, `ANTHEM BLUE CROSS BLUE SHIELD COLORADO`,
`CARESOURCE GEORGIA`. These appear to be delegated or leased network entities
listed as provider groups. The data is real, but `business_name` is not
reliably a provider organization, so organizational ownership requires separate
evidence and cannot be read off this field.
