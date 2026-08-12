#!/usr/bin/env python3
"""Canonical address-key helpers for facility classification.

Extracted from classify_address_building_type.py so the regression tests can
exercise the PRODUCTION functions instead of a copy. The tests previously
defined their own norm() and matcher, which meant production could regress to
substring matching while the tests stayed green -- they were asserting things
about a duplicate implementation, not about shipped behaviour.

The rule these enforce: a hospital campus is asserted ONLY on exact normalized
key equality. Failing to match is the safe direction; a wrong match is not.
"""
import re


def norm(s):
    """Normalize a street line for exact comparison.

    Note this DELIBERATELY truncates at a suite/unit marker, so two suites in
    one building collapse to the same key. That is pre-existing behaviour of
    this classifier, asserted in the tests so a future change is visible.
    """
    s = str(s).upper().strip()
    s = re.sub(r"\bAVENUE\b", "AVE", s)
    s = re.sub(r"\bSTREET\b", "ST", s)
    s = re.sub(r"\bROAD\b", "RD", s)
    s = re.sub(r"\bBOULEVARD\b", "BLVD", s)
    s = re.sub(r"\bDRIVE\b", "DR", s)
    s = re.sub(r"\bPARKWAY\b", "PKWY", s)
    s = re.sub(r"\bSUITE\b.*|\bSTE\b.*|#.*|\bBLDG\b.*|\bP\.O\.\s*BOX\b.*", "", s)
    return re.sub(r"[^\w\s]", "", s).strip()


def address_key(addr, state):
    """Build the {normalized street}_{STATE} key used for matching."""
    return f"{norm(addr)}_{str(state).upper().strip()}"


def is_hospital_campus(midwife_key, hosp_addrs):
    """Exact key equality only.

    This previously also accepted

        any(h_k in midwife_key for h_k in hosp_addrs if len(h_k) > 10)

    a SUBSTRING test, so a hospital at "100 MAIN ST_NY" matched a midwife at
    "2100 MAIN ST_NY" -- street numbers are prefixes of other street numbers
    constantly. That manufactured hospital affiliations that read as
    authoritative and could not be falsified.
    """
    return midwife_key in hosp_addrs
