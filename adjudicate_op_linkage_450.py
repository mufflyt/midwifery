#!/usr/bin/env python3
"""Joint adjudication of the 450-midwife Open Payments linkage overlap.

The diagnosis (artifacts/op_linkage_disagreement_diagnosis.csv,
docs/OPEN_PAYMENTS_LINKAGE_COMPARISON.md) showed the two implementations
disagree 83.6% of the time for two different reasons: most rows compare an
Open Payments address that is not in the NPPES location universe at all, and
the rest are same-address tenant picks. Neither implementation is "wrong" in
the first case -- they answer different questions -- so the adjudication
does not crown a winner per row; it records which answer is usable for the
practice-location estimand this project publishes.

Ruling, per NPI:
  agree                    A and B name the same Type-2 NPI
  b_preferred_universe     A linked an address B never considered
                           (op_addr_is_nppes_practice_addr == False) -- for
                           a practice-location estimand B's universe is the
                           right one; A's org may still be a true billing
                           org, which is why the row is flagged rather than
                           discarded
  b_preferred_tenant       same physical address, B has a single unambiguous
                           candidate, and A named a different tenant
  ambiguous                same address, multiple B candidates -- A's single
                           pick is unjustified and B's set must be carried
                           as a set; canonical_type2_npi stays empty

Input : artifacts/op_linkage_disagreement_diagnosis.csv (450 rows incl.
        header? -- 376 disagreements + 74 agreements live in the diagnosis
        artifact; this script re-derives agreement from the columns)
Output: artifacts/op_linkage_adjudication.csv  (person-level: NPI present,
        gitignored class -- add the sidecar but do not commit either)
        artifacts/op_linkage_adjudication_summary.csv (aggregate, tracked)
"""
import csv
import hashlib
import json
import os
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.abspath(__file__))
IN = os.path.join(ROOT, "artifacts", "op_linkage_disagreement_diagnosis.csv")
OUT = os.path.join(ROOT, "artifacts", "op_linkage_adjudication.csv")
SUM = os.path.join(ROOT, "artifacts", "op_linkage_adjudication_summary.csv")


def sidecar(path, inputs):
    payload = {
        "artifact": os.path.basename(path),
        "generated_by": os.path.basename(__file__),
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "inputs": [
            {"path": i, "sha256": hashlib.sha256(open(i, "rb").read()).hexdigest()}
            for i in inputs
        ],
    }
    with open(path + ".provenance.json", "w") as f:
        json.dump(payload, f, indent=2)


def ruling(row):
    a = row["a_type2_npi"].strip()
    b_list = [x.strip() for x in row["b_type2_npis"].split(";") if x.strip()]
    same_addr = row["op_addr_is_nppes_practice_addr"].strip() == "True"
    n_cand = int(row["n_b_candidates"] or 0)
    if a and a in b_list:
        return "agree", a, "A's pick is in B's candidate set"
    if not same_addr:
        return ("b_preferred_universe", b_list[0] if n_cand == 1 else "",
                "OP address absent from NPPES locations; A and B link "
                "different places -- B's universe governs the "
                "practice-location estimand")
    if n_cand == 1:
        return ("b_preferred_tenant", b_list[0],
                "same address, B unambiguous; A named a different tenant")
    return ("ambiguous", "",
            "same address, multiple B candidates; carry the set, "
            "do not collapse to A's first match")


def main():
    with open(IN, newline="") as f:
        rows = list(csv.DictReader(f))
    out, tally = [], {}
    for r in rows:
        verdict, canon, reason = ruling(r)
        out.append({"npi": r["npi"], "a_type2_npi": r["a_type2_npi"],
                    "b_type2_npis": r["b_type2_npis"],
                    "n_b_candidates": r["n_b_candidates"],
                    "op_addr_is_nppes_practice_addr":
                        r["op_addr_is_nppes_practice_addr"],
                    "ruling": verdict, "canonical_type2_npi": canon,
                    "reason": reason})
        tally[verdict] = tally.get(verdict, 0) + 1
    with open(OUT, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)
    with open(SUM, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ruling", "n", "pct"])
        for k, v in sorted(tally.items()):
            w.writerow([k, v, round(100 * v / len(out), 1)])
    sidecar(OUT, [IN])
    sidecar(SUM, [IN])
    print(f"{len(out)} rows adjudicated: {tally}")


if __name__ == "__main__":
    main()
