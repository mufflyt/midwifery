"""Saboteur tests for harvest_live_pennsylvania_bon_from_tracked_roster.py.

fetch_pa_nurse_midwives() is exercised with a fake opener (no network);
build_pa_lookup / match_cohort_to_pa_bon are exercised with plain in-memory
dicts, mirroring the discipline used for the CA and NM harvester suites.
"""
import json

import pytest

import harvest_live_pennsylvania_bon_from_tracked_roster as pa


def _record(first="", last="", license_no="", status="Active", city="", county="",
            zipcode="", total=1):
    return {"FirstName": first, "LastName": last, "LicenseNumber": license_no,
            "Status": status, "City": city, "County": county, "zipcode": zipcode,
            "TotalRecords": total}


class _FakeResponse:
    def __init__(self, body):
        self._body = json.dumps(body).encode("utf-8")

    def read(self, n=-1):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _cohort_row(cert="C1", first="", last="", nppes_first=None, nppes_last=None, state="PA"):
    return {
        "certification_number": cert,
        "first_name": first,
        "last_name": last,
        "nppes_first_name": nppes_first if nppes_first is not None else first,
        "nppes_last_name": nppes_last if nppes_last is not None else last,
        "nppes_state": state,
    }


# -- fetch_pa_nurse_midwives: pagination and response-shape validation -------

# 1. A single page whose TotalRecords equals its own length stops after
#    page 1 -- no unnecessary second request.
def test_fetch_stops_after_one_page_when_total_matches():
    page = [_record(first="A", last="One", total=1)]
    calls = []

    def opener(req, timeout=None):
        calls.append(req)
        return _FakeResponse(page)

    records, total = pa.fetch_pa_nurse_midwives(opener=opener)
    assert len(records) == 1 and total == 1
    assert len(calls) == 1


# 2. TotalRecords larger than one page's worth triggers a second request,
#    and all records across both pages are concatenated, not just the last.
def test_fetch_pages_until_total_reached():
    page1 = [_record(first="A", last="One", total=2)]
    page2 = [_record(first="B", last="Two", total=2)]
    responses = iter([page1, page2])

    def opener(req, timeout=None):
        return _FakeResponse(next(responses))

    records, total = pa.fetch_pa_nurse_midwives(opener=opener)
    assert total == 2
    assert [r["FirstName"] for r in records] == ["A", "B"]


# 3. An empty first page (zero current licensees -- a real, if surprising,
#    possible answer) must not raise -- TotalRecords=0 stops cleanly.
def test_fetch_accepts_zero_records():
    def opener(req, timeout=None):
        return _FakeResponse([])

    records, total = pa.fetch_pa_nurse_midwives(opener=opener)
    assert records == [] and total == 0


# 4. A response that is not a list of dicts with "TotalRecords" (API
#    changed shape, or an HTML error page) must raise a clear error rather
#    than silently returning an empty/garbage result.
def test_fetch_rejects_unexpected_first_page_shape():
    def opener(req, timeout=None):
        return _FakeResponse({"error": "unexpected"})

    with pytest.raises(RuntimeError, match="unexpected response shape"):
        pa.fetch_pa_nurse_midwives(opener=opener)


# 5. A dict record missing "TotalRecords" entirely on page 1 is also
#    rejected -- the pagination terminator must not silently default to 0.
def test_fetch_rejects_records_missing_total_records_field():
    def opener(req, timeout=None):
        return _FakeResponse([{"FirstName": "A", "LastName": "One"}])

    with pytest.raises(RuntimeError, match="unexpected response shape"):
        pa.fetch_pa_nurse_midwives(opener=opener)


# -- build_pa_lookup ----------------------------------------------------------

# 6. A record missing either first or last name is never indexed under a
#    partial/garbage key.
def test_build_lookup_skips_records_missing_either_name_half():
    lookup = pa.build_pa_lookup([_record(first="", last="ONLYLAST"),
                                  _record(first="ONLYFIRST", last="")])
    assert lookup == {}


# 7. Two live records sharing the same name are both kept as candidates.
def test_build_lookup_keeps_all_candidates_for_duplicate_name():
    lookup = pa.build_pa_lookup([_record(first="JANE", last="SMITH", license_no="1"),
                                  _record(first="JANE", last="SMITH", license_no="2")])
    assert len(lookup["SMITH_JANE"]) == 2


# -- match_cohort_to_pa_bon: the join -----------------------------------------

# 8. An unambiguous name match carries license number, status, city,
#    county and zip through to the output row.
def test_match_unambiguous_name_carries_all_fields():
    pa_records = [_record(first="ASIA", last="ABDUL-HAQQ", license_no="MW008333L",
                           status="Active", city="Philadelphia", county="Philadelphia",
                           zipcode="19111")]
    cohort = [_cohort_row(first="Asia", last="Abdul-Haqq")]
    matched, unmatched = pa.match_cohort_to_pa_bon(cohort, pa_records)
    assert len(matched) == 1 and not unmatched
    m = matched[0]
    assert m["live_bon_license_number"] == "MW008333L"
    assert m["live_bon_city"] == "Philadelphia"
    assert m["live_bon_zip"] == "19111"
    assert m["live_bon_match_status"] == "VERIFIED_LIVE_BON"


# 9. A name colliding with more than one live record is AMBIGUOUS, never
#    guessed.
def test_match_ambiguous_name_is_not_guessed():
    pa_records = [_record(first="JANE", last="SMITH", license_no="1"),
                  _record(first="JANE", last="SMITH", license_no="2")]
    cohort = [_cohort_row(first="Jane", last="Smith")]
    matched, unmatched = pa.match_cohort_to_pa_bon(cohort, pa_records)
    assert not matched and unmatched[0]["live_bon_match_status"] == "AMBIGUOUS"
    assert unmatched[0]["live_bon_license_number"] == "NA"


# 10. No matching live record at all is UNMATCHED, distinct from AMBIGUOUS.
def test_match_unmatched_when_no_candidates():
    pa_records = [_record(first="SOMEONE", last="ELSE")]
    cohort = [_cohort_row(first="Nobody", last="Here")]
    matched, unmatched = pa.match_cohort_to_pa_bon(cohort, pa_records)
    assert not matched and unmatched[0]["live_bon_match_status"] == "UNMATCHED"


# 11. Name matching is case-insensitive.
def test_match_is_case_insensitive():
    pa_records = [_record(first="CASE", last="INSENSITIVE")]
    cohort = [_cohort_row(first="case", last="insensitive")]
    matched, _ = pa.match_cohort_to_pa_bon(cohort, pa_records)
    assert matched and matched[0]["live_bon_match_status"] == "VERIFIED_LIVE_BON"


# 12. Name matching trims incidental whitespace on either side of the join.
def test_match_trims_whitespace():
    pa_records = [_record(first="SPACEY ", last=" NAME")]
    cohort = [_cohort_row(first="Spacey", last=" Name ")]
    matched, _ = pa.match_cohort_to_pa_bon(cohort, pa_records)
    assert matched and matched[0]["live_bon_match_status"] == "VERIFIED_LIVE_BON"


# 13. A blank-named cohort row never accidentally matches a blank-named
#     live record (build_pa_lookup already excludes blank keys, so this
#     must fall through to UNMATCHED).
def test_match_blank_cohort_name_is_not_a_match():
    pa_records = [_record(first="REAL", last="PERSON")]
    cohort = [_cohort_row(first="", last="")]
    matched, unmatched = pa.match_cohort_to_pa_bon(cohort, pa_records)
    assert not matched and unmatched[0]["live_bon_match_status"] == "UNMATCHED"


# 14. End-to-end with an empty cohort returns two empty lists without
#     raising.
def test_match_empty_cohort_returns_empty_without_raising():
    pa_records = [_record(first="SOME", last="ONE")]
    matched, unmatched = pa.match_cohort_to_pa_bon([], pa_records)
    assert matched == [] and unmatched == []
