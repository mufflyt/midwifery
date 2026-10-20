#!/usr/bin/env python3
"""Draw a manual-lookup QA sample: board license numbers vs. Nursys.

WHY A SAMPLE AND NOT A CENSUS. Nursys QuickConfirm has no bulk API (confirmed
by inspection: NCSBN's own support docs state the only Nursys API is
e-Notify, institutional-only, and it can only return data for nurses already
enrolled on the account's Nurse List -- it cannot discover or bulk-query
arbitrary people). QuickConfirm itself is a single-lookup, Cloudflare-gated
verification page with no export function. So this has to be looked up by a
human, one person at a time, which means it has to be a sample, not a census
of the 1,353 WA/CO/TX board-verified midwives.

WHY STRATIFIED BY STATE, NOT A FLAT RANDOM DRAW. The three board sources have
different license-number formats (WA "ARNP.AP.######-CNM", CO a short numeric
ID, TX "AP######"), so a flat draw could easily under-sample the smallest
state (WA, 369) relative to the largest (TX, 498). An equal per-state count
means the agreement rate for each state individually is still estimable, not
swamped by whichever state happened to be biggest.

WHAT THIS DOES NOT DO. It does not query Nursys. It draws the sample and
leaves NURSYS_* columns blank for a human to fill in by hand, respecting
Nursys's own single-lookup design (Search by Name, License type APRN-CNM,
State) rather than attempting to automate around it.

Run: python3 draw_nursys_qa_sample.py [n_per_state]
Output: artifacts/nursys_qa_sample.csv
"""
import csv
import random
import sys

N_PER_STATE = int(sys.argv[1]) if len(sys.argv) > 1 else 40
SEED = 20261019  # fixed, so re-running reproduces the same draw

BON_FILES = {
    "WA": ("artifacts/live_washington_bon_ingested_midwives_from_tracked_roster.csv", "live_bon_credential_num"),
    "CO": ("artifacts/live_colorado_bon_ingested_midwives_from_tracked_roster.csv", "live_bon_credential_num"),
    "TX": ("artifacts/live_texas_bon_ingested_midwives_from_tracked_roster.csv", "live_bon_license_number"),
}
OUT = "artifacts/nursys_qa_sample.csv"


def main():
    rng = random.Random(SEED)
    rows_out = []

    for state, (path, license_field) in BON_FILES.items():
        verified = []
        with open(path, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if row.get("live_bon_match_status") == "VERIFIED_LIVE_BON":
                    verified.append(row)
        k = min(N_PER_STATE, len(verified))
        sample = rng.sample(verified, k)
        sample.sort(key=lambda r: (r["last_name"], r["first_name"]))
        print(f"{state}: drew {k} of {len(verified)} verified board records")

        for row in sample:
            rows_out.append({
                "state": state,
                "certification_number": row["certification_number"],
                "last_name": row["last_name"],
                "first_name": row["first_name"],
                "npi": row["npi"],
                "board_license_number": (row.get(license_field) or "").strip(),
                "nursys_search_instructions": (
                    f"nursys.com/LQC/LQCSearch.aspx -> Search by Name -> "
                    f"Last={row['last_name']}, First={row['first_name']}, "
                    f"License type=APRN-CNM, State={state}"
                ),
                # Filled in by hand after the Nursys lookup:
                "nursys_ncsbn_id": "",
                "nursys_license_number_for_state": "",
                "nursys_license_status": "",
                "match_board_vs_nursys": "",  # yes / no / not_found / ambiguous
                "notes": "",
            })

    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows_out[0].keys()))
        w.writeheader()
        w.writerows(rows_out)

    print(f"\nwrote {len(rows_out)} rows ({N_PER_STATE}/state target) to {OUT}")
    print("Fill in the nursys_* columns and match_board_vs_nursys by hand, "
          "one Nursys QuickConfirm lookup per row.")


if __name__ == "__main__":
    main()
