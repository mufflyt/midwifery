"""Saboteur tests for harvest_live_florida_bon_from_tracked_roster.py.

Covers the pure HTML-parsing functions (parse_detail_page, parse_list_page)
against realistic fixture fragments, and the CNM-qualification decision
logic (resolve_cnm_match) via a fake opener -- no real network. The central
thing under test throughout: Florida has no CNM-specific profession
category, so an APRN name match must never be counted as a midwife unless
the license's own Qualifications field says "Certified Nurse Midwife".
"""
import pytest

import harvest_live_florida_bon_from_tracked_roster as fl


def _detail_html(license_number="APRN1234567", status="Clear/Active",
                  address="123 Main St", city_state_zip="",
                  qualifications=("Certified Nurse Midwife",), no_address_on_file=False):
    qual_html = "".join(f"<dd>{q}</dd>\n" for q in qualifications) if qualifications else ""
    # Real pages render the address as FOUR <dt>/<dd> pairs: street, two
    # blank spacer lines, then "CITY, ST ZIP" -- see parse_detail_page()'s
    # own comment for why. A record with no address on file additionally
    # carries a leading disclaimer paragraph under a FIRST "Address of
    # Record" label before the real four-line block.
    disclaimer = ("<dt>Address of Record</dt><dd><p>This practitioner does not have an "
                  "address of record on file.</p></dd>\n" if no_address_on_file else "")
    address_block = (
        f"{disclaimer}"
        f"<dt>Address of Record</dt><dd>{address}</dd>"
        f"<dt></dt><dd></dd>"
        f"<dt></dt><dd></dd>"
        f"<dt></dt><dd>{city_state_zip}</dd>"
    )
    return f"""
    <h3>JANE DOE </h3>
    <h3>License Number: {license_number} </h3>
    <dt>Profession</dt><dd>Advanced Practice Registered Nurse</dd>
    <dt>License</dt><dd>{license_number}</dd>
    <dt>License Status</dt><dd>{status}</dd>
    <dt>Qualifications</dt>
    {qual_html}<dt>License Expiration Date</dt><dd>4/30/2028</dd>
    {address_block}
    """


def _list_html(entries):
    rows = ""
    for lic_ind, lic_no, name, city, status in entries:
        rows += (f'<td><a href="/MQASearchServices/HealthCareProviders/'
                 f'LicenseVerification?LicInd={lic_ind}&amp;ProCde=1711">{lic_no}</a></td>'
                 f'<td>{name}</td><td>Adv Practice RN</td><td>{city}</td><td>{status}</td>')
    return f"<table><thead></thead><tbody>{rows}</tbody></table>"


class _FakeResponse:
    def __init__(self, body):
        self._body = body.encode("utf-8")

    def read(self, n=-1):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class _FakeOpener:
    """Returns canned bodies in sequence, one per .open() call."""
    def __init__(self, bodies):
        self._bodies = list(bodies)

    def open(self, req, timeout=None):
        return _FakeResponse(self._bodies.pop(0))


# -- parse_detail_page --------------------------------------------------------

# 1. Round-trips license number, status, address and a single qualification.
def test_parse_detail_page_extracts_core_fields():
    d = fl.parse_detail_page(_detail_html(license_number="APRN999", status="Clear/Active",
                                           address="15255 Max Leggett Parkway",
                                           qualifications=["Certified Nurse Midwife"]))
    assert d["license_number"] == "APRN999"
    assert d["status"] == "Clear/Active"
    assert d["address"] == "15255 Max Leggett Parkway"
    assert d["qualifications"] == ["Certified Nurse Midwife"]


# 2. Multiple qualifications are all captured, not just the first.
def test_parse_detail_page_extracts_multiple_qualifications():
    d = fl.parse_detail_page(_detail_html(
        qualifications=["Certified Nurse Midwife", "Nurse Practitioner", "Autonomous Practice APRN"]))
    assert d["qualifications"] == ["Certified Nurse Midwife", "Nurse Practitioner", "Autonomous Practice APRN"]


# 3. A license with no qualifications listed at all does not crash parsing
#    -- it returns an empty list, a real (if unqualified) possible record.
def test_parse_detail_page_handles_zero_qualifications():
    d = fl.parse_detail_page(_detail_html(qualifications=[]))
    assert d["qualifications"] == []


# 4. Non-detail HTML (e.g. a list page or an unrelated error page) returns
#    None -- it must never be silently misparsed into a fake empty record.
def test_parse_detail_page_returns_none_for_non_detail_html():
    assert fl.parse_detail_page(_list_html([("1", "APRN1", "A, B", "CITY", "Clear/Active")])) is None
    assert fl.parse_detail_page("<html><body>404</body></html>") is None


# -- parse_list_page ----------------------------------------------------------

# 5. Extracts every (lic_ind, license_number) pair from a multi-row list.
def test_parse_list_page_extracts_all_candidates():
    body = _list_html([
        ("353025", "APRN9273608", "ADAMS, ADRINE SUE", "WINCHESTER", "Clear/Active"),
        ("681156", "APRN11040537", "ADAMS, ALEXIS BOSQUE", "ORLANDO", "Clear/Active"),
    ])
    candidates = fl.parse_list_page(body)
    assert candidates == [("353025", "APRN9273608"), ("681156", "APRN11040537")]


# 6. A page with no result rows returns an empty list, not an error -- the
#    caller (search_fl_aprn) is responsible for distinguishing "empty list"
#    from "no records found" via the literal message, not this function.
def test_parse_list_page_returns_empty_for_no_rows():
    assert fl.parse_list_page("<table><tbody></tbody></table>") == []


# -- search_fl_aprn: response-shape dispatch ----------------------------------

# 7. "No records found" in the body is recognized regardless of what else
#    is on the page (it's a modal over the still-rendered empty form).
def test_search_recognizes_no_records_found():
    opener = _FakeOpener(["<div>No records found. Please try again.</div>" + _list_html([])])
    result = fl.search_fl_aprn("Nobody", "Here", "tok", opener)
    assert result["type"] == "none"


# 8. A unique match (server redirects straight to the detail page) is
#    recognized as type "detail" with its fields parsed through.
def test_search_recognizes_unique_detail_redirect():
    opener = _FakeOpener([_detail_html(license_number="APRN2562942",
                                        qualifications=["Certified Nurse Midwife", "Nurse Practitioner"])])
    result = fl.search_fl_aprn("Adams", "Casey", "tok", opener)
    assert result["type"] == "detail"
    assert result["license_number"] == "APRN2562942"
    assert "Certified Nurse Midwife" in result["qualifications"]


# 9. Multiple candidates sharing a name are recognized as type "list" with
#    every candidate carried through, not just the first.
def test_search_recognizes_candidate_list():
    opener = _FakeOpener([_list_html([
        ("353025", "APRN9273608", "ADAMS, ADRINE SUE", "WINCHESTER", "Clear/Active"),
        ("681156", "APRN11040537", "ADAMS, ADRINE SUE", "ORLANDO", "Clear/Active"),
    ])])
    result = fl.search_fl_aprn("Adams", "Adrine", "tok", opener)
    assert result["type"] == "list"
    assert len(result["candidates"]) == 2


# 10. A response that is none of the three recognized shapes (site changed,
#     or a transient error page) raises loudly rather than being treated as
#     a silent zero-result search.
def test_search_raises_on_unrecognized_response_shape():
    opener = _FakeOpener(["<html><body>Unexpected maintenance page</body></html>"])
    with pytest.raises(RuntimeError, match="unrecognized response shape"):
        fl.search_fl_aprn("Adams", "Casey", "tok", opener)


# -- fetch_search_token --------------------------------------------------------

# 11. A search page missing the anti-forgery token entirely must raise a
#     clear error, not silently proceed with no token (which would make
#     every subsequent POST fail in a confusing way downstream).
def test_fetch_search_token_raises_when_token_missing():
    opener = _FakeOpener(["<html><body>no token here</body></html>"])
    with pytest.raises(RuntimeError, match="RequestVerificationToken"):
        fl.fetch_search_token(opener)


# -- resolve_cnm_match: the core scope-correctness logic ----------------------

# 12. A unique APRN match whose Qualifications include "Certified Nurse
#     Midwife" is accepted as a real match.
def test_resolve_accepts_unique_cnm_qualified_match():
    opener = _FakeOpener([_detail_html(qualifications=["Certified Nurse Midwife"])])
    out = fl.resolve_cnm_match("Adams", "Melinda", "tok", opener)
    assert out["match_status"] == "VERIFIED_LIVE_BON"


# 13. A unique APRN match whose Qualifications do NOT include "Certified
#     Nurse Midwife" (e.g. a nurse practitioner who happens to share the
#     cohort member's name) must be reported NOT_CNM_QUALIFIED -- never
#     silently counted as a midwife just because an APRN name matched.
def test_resolve_rejects_non_cnm_aprn_as_a_match():
    opener = _FakeOpener([_detail_html(qualifications=["Nurse Practitioner"])])
    out = fl.resolve_cnm_match("Smith", "Jane", "tok", opener)
    assert out["match_status"] == "NOT_CNM_QUALIFIED"


# 14. No record at all is UNMATCHED, distinct from NOT_CNM_QUALIFIED (which
#     means a person WAS found, just not as a midwife).
def test_resolve_unmatched_when_no_record_exists():
    opener = _FakeOpener(['<div>No records found.</div>' + _list_html([])])
    out = fl.resolve_cnm_match("Nobody", "Here", "tok", opener)
    assert out["match_status"] == "UNMATCHED"


# 15. Among several same-named candidates, the ONE that is CNM-qualified is
#     correctly picked out even when it is not first in the list.
def test_resolve_picks_the_cnm_qualified_candidate_among_several():
    opener = _FakeOpener([
        _list_html([
            ("1", "APRN1", "DOE, JANE", "CITYA", "Clear/Active"),
            ("2", "APRN2", "DOE, JANE", "CITYB", "Clear/Active"),
        ]),
        _detail_html(license_number="APRN1", qualifications=["Nurse Practitioner"]),
        _detail_html(license_number="APRN2", qualifications=["Certified Nurse Midwife"]),
    ])
    out = fl.resolve_cnm_match("Doe", "Jane", "tok", opener)
    assert out["match_status"] == "VERIFIED_LIVE_BON"
    assert out["license_number"] == "APRN2"


# 16. If NONE of several same-named candidates is CNM-qualified, the result
#     is NOT_CNM_QUALIFIED, not a false UNMATCHED (a person-match exists,
#     it just isn't a midwife) and not a guessed VERIFIED_LIVE_BON.
def test_resolve_not_cnm_qualified_when_no_candidate_qualifies():
    opener = _FakeOpener([
        _list_html([
            ("1", "APRN1", "DOE, JANE", "CITYA", "Clear/Active"),
            ("2", "APRN2", "DOE, JANE", "CITYB", "Clear/Active"),
        ]),
        _detail_html(license_number="APRN1", qualifications=["Nurse Practitioner"]),
        _detail_html(license_number="APRN2", qualifications=["Autonomous Practice APRN"]),
    ])
    out = fl.resolve_cnm_match("Doe", "Jane", "tok", opener)
    assert out["match_status"] == "NOT_CNM_QUALIFIED"


# 17. Two same-named candidates BOTH CNM-qualified (a genuine, if rare,
#     possibility) must be reported AMBIGUOUS rather than guessed by
#     picking the first.
def test_resolve_ambiguous_when_multiple_candidates_both_cnm_qualified():
    opener = _FakeOpener([
        _list_html([
            ("1", "APRN1", "DOE, JANE", "CITYA", "Clear/Active"),
            ("2", "APRN2", "DOE, JANE", "CITYB", "Clear/Active"),
        ]),
        _detail_html(license_number="APRN1", qualifications=["Certified Nurse Midwife"]),
        _detail_html(license_number="APRN2", qualifications=["Certified Nurse Midwife"]),
    ])
    out = fl.resolve_cnm_match("Doe", "Jane", "tok", opener)
    assert out["match_status"] == "AMBIGUOUS"


# 18. HTML entities in a field (e.g. an apostrophe in an address) are
#     unescaped rather than leaking raw "&#39;"-style markup into output.
def test_parse_detail_page_unescapes_html_entities_in_address():
    d = fl.parse_detail_page(_detail_html(address="123 O&#39;Brien Ave"))
    assert d["address"] == "123 O'Brien Ave"


# -- parse_detail_page: city/state/zip (added 2026-10-26 after discovering --
# -- the original parser only captured the street line) ----------------------

# 19. The "CITY, ST ZIP" line (the fourth <dd> after "Address of Record")
#     is split into separate city/state/zip fields.
def test_parse_detail_page_extracts_city_state_zip():
    d = fl.parse_detail_page(_detail_html(address="15255 Max Leggett Parkway",
                                           city_state_zip="JACKSONVILLE, FL 32218"))
    assert d["city"] == "JACKSONVILLE"
    assert d["state"] == "FL"
    assert d["zip"] == "32218"


# 20. A ZIP+4 is truncated to its first five digits, matching this
#     project's zip5 convention everywhere else.
def test_parse_detail_page_truncates_zip_plus_four():
    d = fl.parse_detail_page(_detail_html(city_state_zip="NAPLES, FL 34114-1234"))
    assert d["zip"] == "34114"


# 21. A record with no address on file (the page renders a disclaimer
#     paragraph under a FIRST "Address of Record" label before the real
#     four-line block) still parses the real block correctly -- the
#     disclaimer's <p>-wrapped <dd> must not be mistaken for the address.
def test_parse_detail_page_skips_no_address_disclaimer_to_find_real_block():
    d = fl.parse_detail_page(_detail_html(address="NOT PRACTICING", city_state_zip="",
                                           no_address_on_file=True))
    assert d["address"] == "NOT PRACTICING"
    assert d["city"] == "" and d["state"] == "" and d["zip"] == ""


# 22. A blank city/state/zip line (no address on file at all, not even
#     "NOT PRACTICING") yields blank city/state/zip, not a crash or a
#     fabricated value.
def test_parse_detail_page_blank_city_state_zip_is_blank_not_fabricated():
    d = fl.parse_detail_page(_detail_html(address="", city_state_zip=""))
    assert d["city"] == "" and d["state"] == "" and d["zip"] == ""


# -- resolve_cnm_match: city/state/zip carried through ------------------------

# 23. A unique CNM-qualified match carries city/state/zip through to the
#     caller, not just license_number/status/address.
def test_resolve_carries_city_state_zip_through_for_unique_match():
    opener = _FakeOpener([_detail_html(qualifications=["Certified Nurse Midwife"],
                                        city_state_zip="NAPLES, FL 34114")])
    out = fl.resolve_cnm_match("Adamczyk", "Lisa", "tok", opener)
    assert out["city"] == "NAPLES"
    assert out["state"] == "FL"
    assert out["zip"] == "34114"


# 24. The CNM-qualified candidate picked out of an ambiguous list also
#     carries its own city/state/zip through, not the other candidate's.
def test_resolve_carries_city_state_zip_through_for_picked_candidate():
    opener = _FakeOpener([
        _list_html([
            ("1", "APRN1", "DOE, JANE", "CITYA", "Clear/Active"),
            ("2", "APRN2", "DOE, JANE", "CITYB", "Clear/Active"),
        ]),
        _detail_html(license_number="APRN1", qualifications=["Nurse Practitioner"],
                     city_state_zip="TAMPA, FL 33601"),
        _detail_html(license_number="APRN2", qualifications=["Certified Nurse Midwife"],
                     city_state_zip="ORLANDO, FL 32801"),
    ])
    out = fl.resolve_cnm_match("Doe", "Jane", "tok", opener)
    assert out["license_number"] == "APRN2"
    assert out["city"] == "ORLANDO"
    assert out["zip"] == "32801"
