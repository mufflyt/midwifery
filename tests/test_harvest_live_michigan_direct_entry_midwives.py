"""Saboteur tests for harvest_live_michigan_direct_entry_midwives.py.

Only fetch_county() carries real logic (regex extraction off the detail
page's value spans, plus the "false"-literal-county normalization found on
live data -- see the module's own header). The list-page search
(fetch_michigan_midwife_list) drives a real browser and is exercised
live, not mocked here, mirroring how this project treats other
browser-dependent steps as outside unit-test scope.
"""
import harvest_live_michigan_direct_entry_midwives as mi


def _detail_html(status="Active", county="Grand Traverse"):
    return (
        "<span id='ctl00_PlaceHolderMain_licenseeGeneralInfo_lblBusinessName2_value'>"
        f"{status}</span>"
        "<span id='ctl00_PlaceHolderMain_licenseeGeneralInfo_lblInsuranceCompany_value'>"
        f"{county}</span>"
    )


class _FakeResponse:
    def __init__(self, html):
        self._body = html.encode("utf-8")

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# 1. A well-formed detail page yields both status and county.
def test_fetch_county_extracts_status_and_county():
    def opener(req, timeout=None):
        return _FakeResponse(_detail_html(status="Active", county="Wayne"))

    status, county = mi.fetch_county("7601000006", opener=opener)
    assert status == "Active"
    assert county == "Wayne"


# 2. The literal string "false" rendered in the county slot (a confirmed,
#    live site quirk -- see license 7601000004 in the module header) is
#    normalized to blank, not kept as a fake county name.
def test_fetch_county_normalizes_literal_false_to_blank():
    def opener(req, timeout=None):
        return _FakeResponse(_detail_html(status="Lapsed", county="false"))

    status, county = mi.fetch_county("7601000004", opener=opener)
    assert status == "Lapsed"
    assert county == ""


# 3. "false" normalization is case-insensitive (defensive -- not yet seen
#    any other case live, but nothing guarantees the site's casing).
def test_fetch_county_normalizes_false_case_insensitively():
    def opener(req, timeout=None):
        return _FakeResponse(_detail_html(status="Active", county="FALSE"))

    _, county = mi.fetch_county("1", opener=opener)
    assert county == ""


# 4. A page missing both value spans entirely (layout changed, or an error
#    body) returns blanks rather than raising -- the caller already treats
#    a per-record fetch failure as non-fatal.
def test_fetch_county_handles_missing_fields_without_raising():
    def opener(req, timeout=None):
        return _FakeResponse("<html><body>not the expected layout</body></html>")

    status, county = mi.fetch_county("1", opener=opener)
    assert status == ""
    assert county == ""


# 5. A real county name that merely CONTAINS "false" as a substring (e.g.
#    a hypothetical town name) is not blanked -- only an exact "false"
#    match triggers the quirk normalization.
def test_fetch_county_does_not_blank_a_name_containing_false_as_substring():
    def opener(req, timeout=None):
        return _FakeResponse(_detail_html(status="Active", county="Falsely County"))

    _, county = mi.fetch_county("1", opener=opener)
    assert county == "Falsely County"
