"""Saboteur tests for harvest_live_mco_network_membership_ca_mi.py.

check_practitioner_listed() is exercised with a fake HTTP opener (no
network), mirroring the discipline used for the state BON harvesters this
session (FL/PA/MA/MD/VA/NJ).
"""
import json

import pytest

import harvest_live_mco_network_membership_ca_mi as mco


class _FakeResponse:
    def __init__(self, body, status=200):
        self._body = json.dumps(body).encode("utf-8")
        self.status = status

    def read(self, n=-1):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


# -- check_practitioner_listed: response-shape validation --------------------

# 1. A populated searchset Bundle (real match) is classified "listed".
def test_listed_when_entry_present():
    body = {"resourceType": "Bundle", "type": "searchset",
            "entry": [{"resource": {"resourceType": "Practitioner", "id": "123"}}]}
    status = mco.check_practitioner_listed("https://example.org/fhir", "1234567890",
                                            opener=lambda req, **kw: _FakeResponse(body))
    assert status == "listed"


# 2. A well-formed but empty searchset Bundle (real "not found", confirmed
#    against IEHP/BCBS-MI live responses) is classified "not_listed", not
#    an error.
def test_not_listed_when_bundle_has_no_entries():
    body = {"resourceType": "Bundle", "id": "relay", "type": "searchset",
            "link": [{"relation": "self", "url": "https://example.org/fhir/Practitioner?identifier=x"}]}
    status = mco.check_practitioner_listed("https://example.org/fhir", "1234567890",
                                            opener=lambda req, **kw: _FakeResponse(body))
    assert status == "not_listed"


# 3. A non-Bundle / non-searchset response (API changed shape, or an
#    OperationOutcome error body returned with HTTP 200) raises a clear
#    error rather than silently reporting "not_listed".
def test_rejects_non_bundle_response():
    body = {"resourceType": "OperationOutcome", "issue": [{"severity": "error"}]}
    with pytest.raises(mco.UnexpectedFhirResponse, match="unexpected response shape"):
        mco.check_practitioner_listed("https://example.org/fhir", "1234567890",
                                       opener=lambda req, **kw: _FakeResponse(body))


# 4. A Bundle of the wrong 'type' (e.g. 'collection' instead of
#    'searchset') is also rejected, not silently trusted.
def test_rejects_bundle_wrong_type():
    body = {"resourceType": "Bundle", "type": "collection", "entry": []}
    with pytest.raises(mco.UnexpectedFhirResponse, match="unexpected response shape"):
        mco.check_practitioner_listed("https://example.org/fhir", "1234567890",
                                       opener=lambda req, **kw: _FakeResponse(body))


# 5. An HTTP error (e.g. a 401/403/500 from a misconfigured endpoint) is
#    surfaced as UnexpectedFhirResponse with the status code, not silently
#    swallowed into "not_listed".
def test_http_error_raises_unexpected_fhir_response():
    import urllib.error

    def raising_opener(req, **kw):
        raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized",
                                      hdrs=None, fp=__import__("io").BytesIO(b'{"error":"no token"}'))

    with pytest.raises(mco.UnexpectedFhirResponse, match="HTTP 401"):
        mco.check_practitioner_listed("https://example.org/fhir", "1234567890", opener=raising_opener)


# -- URL construction ----------------------------------------------------------

# 6. The identifier search parameter is correctly namespaced with the NPI
#    system URI, matching the exact query shape confirmed to work live
#    against IEHP and BCBS Michigan.
def test_identifier_param_uses_npi_system_uri():
    captured = {}

    def capturing_opener(req, **kw):
        captured["url"] = req.full_url
        return _FakeResponse({"resourceType": "Bundle", "type": "searchset"})

    mco.check_practitioner_listed("https://example.org/fhir", "1962780445", opener=capturing_opener)
    assert "identifier=" in captured["url"]
    assert "1962780445" in captured["url"]
    assert "us-npi" in captured["url"]


# -- load_billing_tier / load_cohort_rows: basic shape -----------------------

# 7. load_billing_tier builds an npi -> tier dict from a CSV, keyed exactly
#    on the 'npi' and 'tier' columns the real file uses.
def test_load_billing_tier_builds_npi_keyed_dict(tmp_path):
    csv_path = tmp_path / "tier.csv"
    csv_path.write_text("npi,provider_group,tier\n1234567890,midwife,enrolled_and_billed\n")
    result = mco.load_billing_tier(str(csv_path))
    assert result == {"1234567890": "enrolled_and_billed"}


# -- Resume/checkpoint support -------------------------------------------------
# Added after the first full run lost 2,250 completed queries to one uncaught
# network timeout with zero incremental save -- see check_practitioner_listed's
# broadened except clause and main()'s per-row flush.

# 8. A prior (possibly crashed) run's output file is read back into a set of
#    already-done NPIs, so a resumed run skips them instead of re-querying.
def test_load_done_npis_reads_existing_output(tmp_path):
    out_path = tmp_path / "out.csv"
    out_path.write_text("npi,state,plan_name,provider_group,display_name,network_status,billing_tier\n"
                         "1111111111,CA,IEHP,midwife,A,listed,enrolled_only\n"
                         "2222222222,MI,BCBS,midwife,B,not_listed,neither\n")
    assert mco.load_done_npis(str(out_path)) == {"1111111111", "2222222222"}


# 9. No output file yet (first run, not a resume) is an empty set, not an
#    error.
def test_load_done_npis_missing_file_is_empty_set(tmp_path):
    assert mco.load_done_npis(str(tmp_path / "does_not_exist.csv")) == set()
