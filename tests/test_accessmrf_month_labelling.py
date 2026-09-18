#!/usr/bin/env python3
"""Regression: an ignored `?month=` must never mislabel September as July.

THE BUG THIS LOCKS OUT

AccessMRF's API accepts `?month=2026-07-01` and returns HTTP 200 with the
CURRENT month's files. No error, no warning. Code that requested July, trusted
the parameter, and stamped "July" onto the output produced September data
labelled July -- a silent success, which is worse than a failure because
nothing downstream can detect it.

The fix is that the month written to output is always the month OBSERVED on
each file, never the month requested; and any disagreement raises.

Run:  python3 tests/test_accessmrf_month_labelling.py
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

spec = importlib.util.spec_from_file_location(
    "audit", os.path.join(ROOT, "accessmrf_05_duplication_audit.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

FAILURES = []


def check(name, condition, detail=""):
    if condition:
        print(f"  PASS  {name}")
    else:
        print(f"  FAIL  {name}  {detail}")
        FAILURES.append(name)


def fake_source(month_returned, n=3):
    """An API response that IGNORES the requested month, as the real one does."""
    return {
        "months": ["2026-09-01", "2026-08-01", "2026-07-01"],
        "selectedMonth": month_returned,
        "files": [
            {"fileId": f"f{i}", "fileStem": f"stem_{i}",
             "fileSchema": "IN_NETWORK", "fileDate": month_returned,
             "url": f"https://example.invalid/{i}", "totalCompressedSize": 1000}
            for i in range(n)
        ],
    }


def run():
    print("month-labelling regression")

    # 1. Requesting July while the API returns September must NOT yield rows
    #    labelled July. It must raise.
    audit.get_json = lambda url: fake_source("2026-09-01")
    raised = False
    try:
        audit.audit_payer("TEST", ["slug"], {}, pinned_month="2026-07-01")
    except audit.MonthMismatch:
        raised = True
    except Exception as exc:                                   # noqa: BLE001
        # Zero surviving files is also an acceptable refusal, as long as
        # nothing is labelled July.
        raised = isinstance(exc, (audit.MonthMismatch, SystemExit))
    row = None
    if not raised:
        audit.get_json = lambda url: fake_source("2026-09-01")
        row = audit.audit_payer("TEST", ["slug"], {}, pinned_month="2026-07-01")
    check("July request against September response does not produce July rows",
          raised or (row and row["files_comparison_month"] == 0),
          f"row={row}")

    # 2. Requesting the month the API actually serves works normally.
    audit.get_json = lambda url: fake_source("2026-09-01")
    row = audit.audit_payer("TEST", ["slug"], {}, pinned_month="2026-09-01")
    check("matching month is accepted", row["files_comparison_month"] == 3,
          f"got {row['files_comparison_month']}")
    check("observed_source_month is reported from the file, not the request",
          row["observed_source_month"] == "2026-09-01",
          f"got {row['observed_source_month']}")
    check("requested_month is recorded separately",
          row["requested_month"] == "2026-09-01",
          f"got {row['requested_month']}")

    # 3. A file with no observable month must be excluded, never assigned one.
    blind = fake_source("2026-09-01")
    blind["files"][0]["fileDate"] = ""
    audit.get_json = lambda url: blind
    row = audit.audit_payer("TEST", ["slug"], {}, pinned_month="2026-09-01")
    check("file lacking fileDate is excluded, not stamped with the request",
          row["files_comparison_month"] == 2,
          f"got {row['files_comparison_month']}")

    print("")
    if FAILURES:
        print(f"{len(FAILURES)} FAILED: {FAILURES}")
        return 1
    print("all checks passed")
    return 0


def test_month_labelling_regression():
    """Pytest entry point; retain run() for direct command-line use."""
    assert run() == 0


if __name__ == "__main__":
    sys.exit(run())
