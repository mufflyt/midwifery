#!/usr/bin/env python3
"""Adversarial tests for hospital address-key matching.

These exist because classify_address_building_type.py accepted a SUBSTRING
test alongside exact equality:

    if key in hosp_addrs or any(h_k in key for h_k in hosp_addrs if len(h_k) > 10)

Street numbers are routinely prefixes of other street numbers, so a hospital
at "100 MAIN ST_NY" matched every midwife on "2100 MAIN ST_NY". That
manufactured hospital affiliations that read as authoritative and could not be
falsified.

The rule under test: a hospital campus is asserted ONLY on exact normalized
key equality. A near miss must classify as NOT a hospital campus. Failing to
match is the safe direction; a wrong match is not.

Run: python3 tests/test_address_key_matching.py
"""
import re
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


# THE PRODUCTION FUNCTIONS, imported -- not reimplemented. An earlier version
# of this file defined its own norm() and is_hospital_campus(), so production
# could regress to substring matching while every test here stayed green. These
# now exercise the same code classify_address_building_type.py runs.
from address_keys import norm, address_key, is_hospital_campus


def key(addr, state):
    return address_key(addr, state)


def is_hospital_campus_BUGGY(midwife_key, hosp_addrs):
    """The rule as it was, retained so the tests prove they discriminate."""
    return midwife_key in hosp_addrs or any(
        h_k in midwife_key for h_k in hosp_addrs if len(h_k) > 10
    )


FAILURES = []


def check(name, got, want):
    if got != want:
        FAILURES.append(f"{name}: got {got}, want {want}")
        print(f"  FAIL  {name}: got {got}, want {want}")
    else:
        print(f"  ok    {name}")


def main():
    print("=== street-number prefix collisions (the reported defect) ===")
    cases = [
        ("100 MAIN ST",   "2100 MAIN ST",  "NY"),
        ("12 MAIN ST",    "112 MAIN ST",   "NY"),
        ("1 PARK AVE",    "11 PARK AVE",   "NY"),
        ("1 PARK AVE",    "1100 PARK AVE", "NY"),
        ("200 CENTER RD", "1200 CENTER RD","OH"),
    ]
    for hosp, midwife, st in cases:
        hs = {key(hosp, st)}
        mk = key(midwife, st)
        check(f"{hosp!r} must NOT match {midwife!r}",
              is_hospital_campus(mk, hs), False)

    print("\n=== the tests discriminate: the OLD rule fails these ===")
    caught = 0
    for hosp, midwife, st in cases:
        hs = {key(hosp, st)}
        mk = key(midwife, st)
        if is_hospital_campus_BUGGY(mk, hs):
            caught += 1
    print(f"  old rule wrongly matched {caught} of {len(cases)} near misses")
    if caught == 0:
        FAILURES.append("tests do not discriminate: old rule passed them too")
        print("  FAIL  these tests would have passed before the fix")
    else:
        print("  ok    tests fail against the pre-fix implementation")

    print("\n=== legitimate exact matches must STILL match ===")
    for addr, st in [("100 MAIN ST", "NY"), ("1 PARK AVE", "NY"),
                     ("500 DOYLE PARK DR", "CA")]:
        hs = {key(addr, st)}
        check(f"exact {addr!r}", is_hospital_campus(key(addr, st), hs), True)

    print("\n=== normalization equivalences must still match ===")
    hs = {key("100 MAIN STREET", "NY")}
    check("STREET vs ST", is_hospital_campus(key("100 MAIN ST", "NY"), hs), True)
    hs = {key("1 PARK AVENUE", "NY")}
    check("AVENUE vs AVE", is_hospital_campus(key("1 PARK AVE", "NY"), hs), True)

    print("\n=== state must participate in the key ===")
    hs = {key("100 MAIN ST", "NY")}
    check("same street, different state",
          is_hospital_campus(key("100 MAIN ST", "NJ"), hs), False)

    print("\n=== suite/apartment: normalizer strips them, so these collapse ===")
    hs = {key("100 MAIN ST", "NY")}
    check("suite stripped still matches campus",
          is_hospital_campus(key("100 MAIN ST STE 200", "NY"), hs), True)
    # Documented consequence: two suites in one building are indistinguishable
    # after normalization. That is the existing normalizer's behaviour, not
    # something this fix changes; it is asserted so a future change is visible.
    check("two different suites collapse to the same key",
          key("100 MAIN ST STE 200", "NY") == key("100 MAIN ST STE 300", "NY"),
          True)

    print("\n=== directional prefixes and suffixes are NOT interchangeable ===")
    hs = {key("100 N MAIN ST", "NY")}
    check("N MAIN vs MAIN", is_hospital_campus(key("100 MAIN ST", "NY"), hs), False)
    hs = {key("100 MAIN ST N", "NY")}
    check("MAIN ST N vs MAIN ST S",
          is_hospital_campus(key("100 MAIN ST S", "NY"), hs), False)

    print("\n=== empty / missing addresses never assert a campus ===")
    hs = {key("100 MAIN ST", "NY")}
    for bad in ["", "   ", None]:
        check(f"empty address {bad!r}", is_hospital_campus(key(bad or "", "NY"), hs), False)

    print()
    if FAILURES:
        print(f"FAILED: {len(FAILURES)}")
        for f in FAILURES:
            print(f"  - {f}")
        return 1
    print("All address-key tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
