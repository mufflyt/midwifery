#!/usr/bin/env python3
"""
Order-independent saturation curve for the UHC sample.

THE PROBLEM THIS SOLVES

A cumulative-discovery curve computed in one file order is an artifact of that
order. If broad-network files happen to come first, the curve looks saturated
early; if narrow employer files lead, it looks linear. Either way a single
ordering is not evidence about saturation.

So the curve is recomputed under many random permutations of the sampled files
and reported as a distribution -- median with 5th and 95th percentiles -- at
10, 25, 50, 75 and 100 files.

HOW IT IS COMPUTED EFFICIENTLY

Naively this is (permutations x checkpoints) set unions. Instead, note that
under a given ordering a pair is "discovered" at the position of the FIRST file
containing it. So for each permutation:

    position[file]      = rank of that file in the permutation
    first_seen[pair]    = min over the files containing it
    cumulative(k)       = count of pairs whose first_seen < k

That is one grouped-minimum per permutation over the (pair, file) membership
table, done with numpy reduceat rather than Python loops.
"""

import csv
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import accessmrf_config as cfg                                     # noqa: E402

CHECKPOINTS = [10, 25, 50, 75, 100]
N_PERMUTATIONS = 100
SEED = 20260916


def main():
    print(cfg.describe())
    manifest_dir = cfg.subdir("manifests")
    membership_path = os.path.join(manifest_dir, "uhc_sample_membership.csv")

    if not os.path.exists(membership_path):
        raise SystemExit(f"{membership_path} not found; run "
                         f"accessmrf_07_uhc_sample.py first")

    pair_idx, file_idx = [], []
    with open(membership_path) as handle:
        reader = csv.reader(handle)
        next(reader, None)
        for row in reader:
            pair_idx.append(int(row[0]))
            file_idx.append(int(row[1]))

    pairs = np.asarray(pair_idx, dtype=np.int64)
    files = np.asarray(file_idx, dtype=np.int64)
    n_files = int(files.max()) + 1 if files.size else 0
    n_pairs = int(pairs.max()) + 1 if pairs.size else 0

    print(f"[DATA] memberships={pairs.size:,} pairs={n_pairs:,} files={n_files}")

    # Group memberships by pair once, so each permutation is a reduceat.
    order = np.argsort(pairs, kind="stable")
    pairs_sorted = pairs[order]
    files_sorted = files[order]
    boundaries = np.flatnonzero(np.r_[True, pairs_sorted[1:] != pairs_sorted[:-1]])

    rng = np.random.default_rng(SEED)
    checkpoints = [c for c in CHECKPOINTS if c <= n_files]
    results = {c: [] for c in checkpoints}

    for _ in range(N_PERMUTATIONS):
        permutation = rng.permutation(n_files)
        positions = np.empty(n_files, dtype=np.int64)
        positions[permutation] = np.arange(n_files)

        first_seen = np.minimum.reduceat(positions[files_sorted], boundaries)
        counts = np.bincount(first_seen, minlength=n_files)
        cumulative = np.cumsum(counts)

        for c in checkpoints:
            results[c].append(int(cumulative[c - 1]))

    total = int(cumulative[-1])

    rows = []
    print("")
    print("=" * 78)
    print("ORDER-INDEPENDENT DISCOVERY CURVE "
          f"({N_PERMUTATIONS} permutations, seed {SEED})")
    print("=" * 78)
    print(f"{'files':>7}{'median pairs':>16}{'p5':>14}{'p95':>14}{'% of total':>13}")
    for c in checkpoints:
        values = np.asarray(results[c])
        median = float(np.median(values))
        p5, p95 = np.percentile(values, [5, 95])
        rows.append({"files": c, "median_pairs": median, "p5": float(p5),
                     "p95": float(p95),
                     "pct_of_total": 100 * median / max(total, 1)})
        print(f"{c:>7}{median:>16,.0f}{p5:>14,.0f}{p95:>14,.0f}"
              f"{100 * median / max(total, 1):>12.1f}%")

    print("-" * 78)
    print(f"total unique pairs across all {n_files} files: {total:,}")

    # The prespecified expansion rule, evaluated on the permutation median so
    # the decision does not depend on one arbitrary file order either.
    if len(checkpoints) >= 2 and checkpoints[-1] == 100:
        at_75 = float(np.median(results[75]))
        at_100 = float(np.median(results[100]))
        marginal = 100 * (at_100 - at_75) / max(at_100, 1)
        print(f"last 25 files add {marginal:.2f}% of cumulative pairs (median order)")
        if marginal < 1:
            verdict = "STRONGLY SATURATED -> stop at 100 (prespecified rule)"
        elif marginal <= 5:
            verdict = "PARTIAL SATURATION -> expand to 200 (prespecified rule)"
        else:
            verdict = "NOT SATURATED -> expand to 200 and reassess (prespecified rule)"
        print(f"verdict: {verdict}")
        rows.append({"files": "rule", "median_pairs": marginal, "p5": "",
                     "p95": "", "pct_of_total": verdict})

    out = os.path.join(manifest_dir, "uhc_permutation_curve.csv")
    with open(out, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"written: {out}")
    print("=" * 78)


if __name__ == "__main__":
    sys.exit(main())
