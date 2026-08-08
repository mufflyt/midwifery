"""Tests for the NPPES candidate fetcher's pure logic (fetch_npi_candidates.py).

Covers the cache loader (tolerant of a truncated final line) and the
result-set -> candidate-rows transform (address selection, primary-taxonomy
fallback, name-variant expansion, dedup). No network access.
"""
import json

import pytest

import fetch_npi_candidates as fnc


# --- load_cache --------------------------------------------------------------

def test_load_cache_missing_file_returns_empty(monkeypatch, tmp_path):
    monkeypatch.setattr(fnc, "CACHE", str(tmp_path / "does_not_exist.jsonl"))
    assert fnc.load_cache() == {}


def test_load_cache_reads_records_keyed_by_query(monkeypatch, tmp_path):
    path = tmp_path / "cache.jsonl"
    path.write_text(
        json.dumps({"query": "SMITH|", "results": [{"number": "1"}]}) + "\n"
        + json.dumps({"query": "DOE|JANE", "results": []}) + "\n"
    )
    monkeypatch.setattr(fnc, "CACHE", str(path))
    cache = fnc.load_cache()
    assert cache["SMITH|"] == [{"number": "1"}]
    assert cache["DOE|JANE"] == []


def test_load_cache_tolerates_truncated_final_line(monkeypatch, tmp_path):
    # An interrupted run can leave a half-written final line; it must be skipped,
    # not crash the whole re-run.
    path = tmp_path / "cache.jsonl"
    path.write_text(
        json.dumps({"query": "OK|", "results": [{"number": "9"}]}) + "\n"
        + '{"query": "TRUNC|", "resu'
    )
    monkeypatch.setattr(fnc, "CACHE", str(path))
    cache = fnc.load_cache()
    assert cache == {"OK|": [{"number": "9"}]}


# --- build_candidate_rows ----------------------------------------------------

def _provider(**over):
    base = {
        "number": "1000000001",
        "basic": {"first_name": "Jane", "last_name": "Smith",
                  "middle_name": "Q", "credential": "CNM, MSN", "sex": "F",
                  "enumeration_date": "2010-05-01"},
        "addresses": [
            {"address_purpose": "MAILING", "address_1": "PO Box 1",
             "city": "Mailtown", "state": "NY", "postal_code": "10001"},
            {"address_purpose": "LOCATION", "address_1": "1 Clinic Way",
             "city": "Careville", "state": "CA", "postal_code": "902101234"},
        ],
        "taxonomies": [
            {"code": "163W00000X", "desc": "Registered Nurse", "primary": False},
            {"code": "367A00000X", "desc": "Advanced Practice Midwife",
             "primary": True},
        ],
        "other_names": [],
    }
    base.update(over)
    return base


def test_build_rows_picks_location_address_over_mailing():
    (row,) = fnc.build_candidate_rows([[_provider()]])
    assert row["practice_address"] == "1 CLINIC WAY"
    assert row["practice_city"] == "CAREVILLE"
    assert row["practice_state"] == "CA"
    assert row["address_purpose"] == "LOCATION"


def test_build_rows_truncates_zip_to_five_digits():
    (row,) = fnc.build_candidate_rows([[_provider()]])
    assert row["practice_zip"] == "90210"


def test_build_rows_uses_primary_taxonomy_and_joins_all_codes():
    (row,) = fnc.build_candidate_rows([[_provider()]])
    assert row["taxonomy"] == "367A00000X"
    assert row["taxonomy_desc"] == "Advanced Practice Midwife"
    assert row["all_taxonomies"] == "163W00000X|367A00000X"


def test_build_rows_falls_back_to_first_address_when_no_location():
    p = _provider(addresses=[
        {"address_purpose": "MAILING", "address_1": "PO Box 1",
         "city": "Mailtown", "state": "NY", "postal_code": "10001"}])
    (row,) = fnc.build_candidate_rows([[p]])
    assert row["practice_city"] == "MAILTOWN"
    # The fallback records that this is a MAILING address, not a practice site.
    assert row["address_purpose"] == "MAILING"


def test_build_rows_handles_provider_with_no_taxonomies():
    p = _provider(taxonomies=[])
    (row,) = fnc.build_candidate_rows([[p]])
    assert row["taxonomy"] == ""
    assert row["all_taxonomies"] == ""


def test_build_rows_emits_a_row_per_other_name_variant():
    p = _provider(other_names=[
        {"first_name": "Jane", "last_name": "Jones", "middle_name": "Q",
         "type": "former"}])
    rows = fnc.build_candidate_rows([[p]])
    variants = {(r["last_name"], r["name_variant"]) for r in rows}
    assert ("SMITH", "legal") in variants
    assert ("JONES", "former") in variants


def test_build_rows_dedups_on_npi_name_and_variant_kind():
    # The same provider can surface from two surname queries; identical
    # (npi, first, last, kind) rows collapse to one.
    p = _provider()
    rows = fnc.build_candidate_rows([[p], [p]])
    assert len(rows) == 1


def test_build_rows_skips_name_variants_with_no_last_name():
    p = _provider(other_names=[
        {"first_name": "NoLast", "last_name": None, "type": "other"}])
    rows = fnc.build_candidate_rows([[p]])
    assert all(r["last_name"] for r in rows)
    assert len(rows) == 1   # only the legal name survives
