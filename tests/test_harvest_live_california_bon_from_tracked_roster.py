"""Saboteur tests for harvest_live_california_bon_from_tracked_roster.py.

fetch_ca_bon_rows() is exercised with a fake opener (no network); the
matching join (match_cohort_to_ca_bon / build_ca_lookup) is exercised with
plain in-memory dicts. Each test either feeds adversarial input and asserts
a loud, clear failure, or asserts a specific matching-priority rule holds,
mirroring the discipline used for the NM harvester's test suite.
"""
import io

import pytest

import harvest_live_california_bon_from_tracked_roster as ca


def _tsv(rows, header=None):
    header = header or ["Agency Code", "Agency Name", "LicTypeCode", "License Type",
                         "License Number", "Indiv/Org", "Org/Last Name", "First Name",
                         "Middle Name", "Suffix", "Address Line 1", "Address Line 2",
                         "City", "County", "State", "Zip", "Country",
                         "Original Issue Date", "Expiration Date", "License Status"]
    lines = ["\t".join(header)]
    for r in rows:
        lines.append("\t".join(r.get(h, "") for h in header))
    return "\n".join(lines)


def _bon_row(license_type="Nurse Midwife", ln="", fn="", license_no="", status="Current",
             city="", county=""):
    return {"License Type": license_type, "Org/Last Name": ln, "First Name": fn,
            "License Number": license_no, "License Status": status, "City": city,
            "County": county, "Indiv/Org": "I"}


class _FakeResponse:
    def __init__(self, body):
        self._body = body.encode("utf-8")

    def read(self, n=-1):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _cohort_row(cert="C1", first="", last="", nppes_first=None, nppes_last=None, state="CA"):
    return {
        "certification_number": cert,
        "first_name": first,
        "last_name": last,
        "nppes_first_name": nppes_first if nppes_first is not None else first,
        "nppes_last_name": nppes_last if nppes_last is not None else last,
        "nppes_state": state,
    }


# -- fetch_ca_bon_rows: file parsing ----------------------------------------

# 1. Only rows with License Type == "Nurse Midwife" are returned -- other
#    license types present in the same file (e.g. Nurse Practitioner,
#    Registered Nurse) must be filtered out, not accidentally included.
def test_fetch_filters_to_nurse_midwife_only():
    body = _tsv([
        _bon_row(license_type="Nurse Midwife", ln="SMITH", fn="JANE"),
        _bon_row(license_type="Registered Nurse", ln="DOE", fn="JOHN"),
        _bon_row(license_type="Nurse Midwife Furnishing", ln="LEE", fn="KIM"),
    ])
    rows, _ = ca.fetch_ca_bon_rows(opener=lambda req, **kw: _FakeResponse(body))
    assert len(rows) == 1
    assert rows[0]["Org/Last Name"] == "SMITH"


# 2. A file with the right shape but zero Nurse Midwife rows returns an
#    empty list without raising -- a real (if surprising) possible answer,
#    not treated as a parse failure.
def test_fetch_accepts_zero_nurse_midwife_rows():
    body = _tsv([_bon_row(license_type="Registered Nurse", ln="DOE", fn="JOHN")])
    rows, _ = ca.fetch_ca_bon_rows(opener=lambda req, **kw: _FakeResponse(body))
    assert rows == []


# 3. A response that is not this tab-delimited file at all (e.g. an HTML
#    error page from a broken Box redirect) must raise a clear error rather
#    than silently returning zero rows that look like "no midwives found".
def test_fetch_rejects_response_missing_expected_columns():
    with pytest.raises(RuntimeError, match="unexpected file shape"):
        ca.fetch_ca_bon_rows(opener=lambda req, **kw: _FakeResponse("<html>404</html>"))


# 4. The real file is TAB-delimited; a comma-delimited lookalike (e.g. if
#    Box ever changed export format) must not be silently misparsed into a
#    single giant bogus column -- it should fail the shape check instead of
#    producing garbage matches.
def test_fetch_rejects_comma_delimited_lookalike():
    csv_body = "Agency Code,Agency Name,LicTypeCode,License Type,License Number\n400,BRN,4008,Nurse Midwife,123"
    with pytest.raises(RuntimeError, match="unexpected file shape"):
        ca.fetch_ca_bon_rows(opener=lambda req, **kw: _FakeResponse(csv_body))


# 5. Round-trip: a realistic multi-row file preserves License Number,
#    status, city and county verbatim for the filtered rows.
def test_fetch_round_trips_realistic_fields():
    body = _tsv([_bon_row(license_type="Nurse Midwife", ln="ARCHULETA", fn="REBECCA",
                           license_no="236420", status="Current", city="SAN DIEGO",
                           county="SAN DIEGO")])
    rows, _ = ca.fetch_ca_bon_rows(opener=lambda req, **kw: _FakeResponse(body))
    assert rows[0]["License Number"] == "236420"
    assert rows[0]["License Status"] == "Current"
    assert rows[0]["City"] == "SAN DIEGO"
    assert rows[0]["County"] == "SAN DIEGO"


# -- build_ca_lookup ----------------------------------------------------------

# 6. A row missing either first or last name must not be indexed under a
#    partial/garbage key.
def test_build_lookup_skips_rows_missing_either_name_half():
    rows = [_bon_row(ln="", fn="ONLYFIRST"), _bon_row(ln="ONLYLAST", fn="")]
    lookup = ca.build_ca_lookup(rows)
    assert lookup == {}


# 7. Two live BRN records sharing the same name (a real possibility with a
#    common name) are both kept as candidates, not silently collapsed to one.
def test_build_lookup_keeps_all_candidates_for_duplicate_name():
    rows = [_bon_row(ln="SMITH", fn="JANE", license_no="1"),
            _bon_row(ln="SMITH", fn="JANE", license_no="2")]
    lookup = ca.build_ca_lookup(rows)
    assert len(lookup["SMITH_JANE"]) == 2


# -- match_cohort_to_ca_bon: the join ----------------------------------------

# 8. A cohort member with exactly one matching live BRN name is matched,
#    carrying through license number, status, city and county.
def test_match_unambiguous_name():
    ca_rows = [_bon_row(ln="ARCHULETA", fn="REBECCA", license_no="236420",
                         status="Current", city="ALBUQUERQUE", county="BERNALILLO")]
    cohort = [_cohort_row(first="Rebecca", last="Archuleta")]
    matched, unmatched = ca.match_cohort_to_ca_bon(cohort, ca_rows)
    assert len(matched) == 1 and not unmatched
    assert matched[0]["live_bon_license_number"] == "236420"
    assert matched[0]["live_bon_match_status"] == "VERIFIED_LIVE_BON"


# 9. A name colliding with more than one live record is reported
#     AMBIGUOUS, never guessed by picking one.
def test_match_ambiguous_name_is_not_guessed():
    ca_rows = [_bon_row(ln="SMITH", fn="JANE", license_no="1"),
               _bon_row(ln="SMITH", fn="JANE", license_no="2")]
    cohort = [_cohort_row(first="Jane", last="Smith")]
    matched, unmatched = ca.match_cohort_to_ca_bon(cohort, ca_rows)
    assert not matched and len(unmatched) == 1
    assert unmatched[0]["live_bon_match_status"] == "AMBIGUOUS"
    assert unmatched[0]["live_bon_license_number"] == "NA"


# 10. No matching live record at all is reported UNMATCHED, distinctly
#     from AMBIGUOUS.
def test_match_unmatched_when_no_candidates():
    ca_rows = [_bon_row(ln="SOMEONE", fn="ELSE")]
    cohort = [_cohort_row(first="Nobody", last="Here")]
    matched, unmatched = ca.match_cohort_to_ca_bon(cohort, ca_rows)
    assert not matched and unmatched[0]["live_bon_match_status"] == "UNMATCHED"


# 11. Name matching normalizes case: an all-lowercase cohort name still
#     matches an all-uppercase live record.
def test_match_is_case_insensitive():
    ca_rows = [_bon_row(ln="INSENSITIVE", fn="CASE")]
    cohort = [_cohort_row(first="case", last="insensitive")]
    matched, _ = ca.match_cohort_to_ca_bon(cohort, ca_rows)
    assert matched and matched[0]["live_bon_match_status"] == "VERIFIED_LIVE_BON"


# 12. Name matching tolerates incidental leading/trailing whitespace on
#     either side of the join.
def test_match_trims_whitespace():
    ca_rows = [_bon_row(ln=" NAME", fn="SPACEY ")]
    cohort = [_cohort_row(first="Spacey", last=" Name ")]
    matched, _ = ca.match_cohort_to_ca_bon(cohort, ca_rows)
    assert matched and matched[0]["live_bon_match_status"] == "VERIFIED_LIVE_BON"


# 13. A cohort row with a blank name (missing nppes_first_name/last_name AND
#     first_name/last_name) must not accidentally match a live BRN record
#     that is also somehow indexed blank -- build_ca_lookup already
#     excludes blank-keyed entries, so this must fall to UNMATCHED.
def test_match_blank_cohort_name_is_not_a_match():
    ca_rows = [_bon_row(ln="REAL", fn="PERSON")]
    cohort = [_cohort_row(first="", last="")]
    matched, unmatched = ca.match_cohort_to_ca_bon(cohort, ca_rows)
    assert not matched and unmatched[0]["live_bon_match_status"] == "UNMATCHED"


# 14. A cohort row outside CA is still processed correctly if ever passed
#     in directly (load_ca_cohort_rows is what filters by state upstream) --
#     match_cohort_to_ca_bon itself must not silently drop or mis-key rows
#     based on nppes_state; it only uses name fields for the join.
def test_match_ignores_state_field_for_the_join_itself():
    ca_rows = [_bon_row(ln="OUTOFSTATE", fn="PERSON")]
    cohort = [_cohort_row(first="Person", last="Outofstate", state="TX")]
    matched, _ = ca.match_cohort_to_ca_bon(cohort, ca_rows)
    assert matched and matched[0]["nppes_state"] == "TX"


# 15. End-to-end with an empty cohort returns two empty lists without
#     raising.
def test_match_empty_cohort_returns_empty_without_raising():
    ca_rows = [_bon_row(ln="SOME", fn="ONE")]
    matched, unmatched = ca.match_cohort_to_ca_bon([], ca_rows)
    assert matched == [] and unmatched == []
