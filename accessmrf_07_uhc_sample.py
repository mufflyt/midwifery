#!/usr/bin/env python3
"""
UnitedHealthcare stratified sample: does the extractor generalise to a large,
employer-fragmented payer, and does relationship discovery saturate?

This is Project A (provider -> billing/contracting entity), NOT Colorado
access. Files are never selected for looking Colorado-related.

WHY PARTIAL FETCHES

UHC's in-network files have a median compressed size of ~10.5 GB; the largest
is 16 GB, and the September listing totals ~60.8 TB. Downloading 100 of them
would need roughly a terabyte.

They do not need to be downloaded. In UHC's largest file the whole
`provider_references` block occupies bytes 164 through ~126,000,000
(decompressed) and `in_network` -- the entire rate body -- begins only after
it. The server honours HTTP range requests (206), so a range fetch of the first
few tens of MB captures the complete provider block. Measured: 100 MB
compressed arrives in 4.9 s and decompresses to 600 MB, containing 180,766
provider_references entries with 3.2M NPI occurrences.

A size ladder handles files whose block runs longer: fetch, try to parse, and
if the array has not closed, refetch a larger prefix.

MONTH LIMITATION, STATED PLAINLY

AccessMRF's API returns only the CURRENT month. `?month=`, `?selectedMonth=`,
`?date=`, `?fileDate=` are all ignored -- every one returns 2026-09-01. The
`months` array advertises older vintages but there is no exposed way to fetch
them. This sample is therefore drawn from 2026-09, which is still accumulating.

That is acceptable for THIS question: within-payer saturation and structural
compatibility are measured inside a single month. It is NOT acceptable for
comparing file counts between payers, which this script does not do.
"""

import argparse
import collections
import csv
import gzip
import hashlib
import importlib.util
import io
import json
import os
import random
import re
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import accessmrf_config as cfg                                     # noqa: E402


def _load(name):
    spec = importlib.util.spec_from_file_location(
        name.replace(".py", ""), os.path.join(HERE, name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


puller = _load("accessmrf_03_pull_provider_refs.py")
builder = _load("accessmrf_06_build_relationships.py")

UHC_SLUG = "united-healthcare-3e137223de3b464c9de76a5887a32757"
SEED = 20260916
LADDER_MB = [32, 96, 256, 640]        # compressed prefix sizes to try, in order


def stem_family(stem):
    """Coarse family from the filename, for stratification.

    UHC stems look like
      2026-09-01_<ENTITY>_<ROLE>_<EMPLOYER>_<PLAN>_in-network-rates
    The entity+role prefix is the stable part; the employer is the long tail.
    """
    parts = re.sub(r"^\d{4}-\d{2}-\d{2}_", "", stem).split("_")
    return "_".join(parts[:2])[:48] if parts else "(none)"


def size_band(size):
    if size <= 0:
        return "0_unavailable"
    mb = size / 1e6
    if mb < 100:
        return "1_under_100MB"
    if mb < 1000:
        return "2_100MB_1GB"
    if mb < 8000:
        return "3_1GB_8GB"
    if mb < 12000:
        return "4_8GB_12GB"
    return "5_over_12GB"


def build_frame(files):
    frame = []
    for f in files:
        if f.get("fileSchema") != "IN_NETWORK":
            continue
        size = f.get("totalCompressedSize") or 0
        frame.append({
            "file_id": f["fileId"],
            "file_name": f["fileStem"],
            "file_stem_family": stem_family(f["fileStem"]),
            "compressed_size": size,
            "size_band": size_band(size),
            "source_url": f.get("url", ""),
            "source_month": f.get("fileDate", ""),
            "num_parts_available": f.get("numPartsAvailable", 0),
        })
    return frame


def stratified_sample(frame, n, seed):
    """Proportional allocation across size_band x stem_family, fixed seed.

    Every stratum with any file contributes at least one, so rare families and
    the extreme size bands are represented rather than swamped by the modal
    stratum.
    """
    rng = random.Random(seed)
    usable = [f for f in frame if f["num_parts_available"] > 0]
    strata = collections.defaultdict(list)
    for f in usable:
        strata[(f["size_band"], f["file_stem_family"])].append(f)

    for key in strata:
        strata[key].sort(key=lambda f: f["file_id"])

    # ALLOCATION MUST TERMINATE WHEN STRATA OUTNUMBER THE BUDGET.
    # UHC has 129 (size_band x stem_family) strata against n=100. An earlier
    # version gave every stratum a floor of 1, then tried to trim the excess by
    # decrementing allocations greater than 1 -- with all 129 sitting at 1
    # nothing was ever decremented and the loop spun forever (18 minutes of CPU
    # before it was caught).
    #
    # Two stages instead, both terminating by construction:
    #   1. one slot per SIZE BAND, so the smallest and largest files are always
    #      represented even though bands are wildly uneven (86% of UHC files
    #      sit in a single band);
    #   2. the remainder allocated across strata proportional to stratum size
    #      by the largest-remainder method, which gives 0 to the smallest
    #      strata rather than looping.
    total = len(usable)
    keys = sorted(strata, key=lambda k: (-len(strata[k]), k))
    allocation = {k: 0 for k in keys}

    # Stage 1: guarantee every size band appears, via its largest stratum.
    for band in sorted({k[0] for k in keys}):
        band_keys = [k for k in keys if k[0] == band]
        if band_keys and n > 0:
            allocation[band_keys[0]] = 1

    remaining = n - sum(allocation.values())

    # Stage 2: largest-remainder proportional allocation of what is left.
    if remaining > 0:
        exact = {k: remaining * len(strata[k]) / total for k in keys}
        for k in keys:
            allocation[k] += int(exact[k])
        short = n - sum(allocation.values())
        by_remainder = sorted(keys, key=lambda k: (-(exact[k] % 1), k))
        for k in by_remainder:
            if short <= 0:
                break
            allocation[k] += 1
            short -= 1

    # Never ask a stratum for more files than it holds; redistribute the excess.
    overflow = 0
    for k in keys:
        if allocation[k] > len(strata[k]):
            overflow += allocation[k] - len(strata[k])
            allocation[k] = len(strata[k])
    for k in keys:
        if overflow <= 0:
            break
        room = len(strata[k]) - allocation[k]
        take = min(room, overflow)
        allocation[k] += take
        overflow -= take

    chosen = []
    for key in keys:
        if allocation[key]:
            chosen.extend(rng.sample(strata[key], allocation[key]))

    rng.shuffle(chosen)                                 # arbitrary list order
    return chosen[:n]


def fetch_prefix(url, destination, megabytes):
    """Range-fetch the first N MB. Returns bytes written."""
    request = urllib.request.Request(
        url, headers={"User-Agent": puller.UA,
                      "Range": f"bytes=0-{megabytes * 1024 * 1024 - 1}"})
    with urllib.request.urlopen(request, timeout=900,
                                context=puller.SSL_CONTEXT) as response, \
            open(destination, "wb") as handle:
        written = 0
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            handle.write(chunk)
            written += len(chunk)
    return written


def decompress_prefix(source, destination):
    """Expand a truncated gzip prefix, tolerating the inevitable tail error."""
    written = 0
    with open(source, "rb") as raw, open(destination, "wb") as out:
        magic = raw.read(2)
        raw.seek(0)
        stream = gzip.GzipFile(fileobj=raw) if magic == b"\x1f\x8b" else raw
        try:
            while True:
                chunk = stream.read(1 << 22)
                if not chunk:
                    break
                out.write(chunk)
                written += len(chunk)
        except (EOFError, OSError, gzip.BadGzipFile):
            pass                                        # truncation expected
    return written


def acquire_and_parse(entry, scratch_dir, entity_types):
    """Range-fetch with a size ladder until provider_references closes."""
    detail = puller.get_json(f"{puller.API}/files/{entry['file_id']}")
    parts = [p for p in detail.get("fileParts", []) if p.get("isAvailable")]
    if not parts:
        return None, {"parse_status": "no_available_parts"}
    url = parts[0]["fullPath"]

    gz_path = os.path.join(scratch_dir, "prefix.gz")
    json_path = os.path.join(scratch_dir, "prefix.json")

    for megabytes in LADDER_MB:
        try:
            raw_bytes = fetch_prefix(url, gz_path, megabytes)
        except Exception as exc:                        # noqa: BLE001
            return None, {"parse_status": f"fetch_error: {type(exc).__name__}"}

        decompress_prefix(gz_path, json_path)
        try:
            references = puller.stream_provider_references(json_path)
        except Exception:                               # noqa: BLE001
            references = None

        if references is not None:
            return references, {"parse_status": "parsed",
                                "prefix_mb": megabytes,
                                "raw_bytes": raw_bytes}
        if raw_bytes < megabytes * 1024 * 1024:
            return None, {"parse_status": "no_provider_references_whole_file",
                          "prefix_mb": megabytes, "raw_bytes": raw_bytes}

    return None, {"parse_status": f"block_exceeds_{LADDER_MB[-1]}MB_prefix",
                  "prefix_mb": LADDER_MB[-1]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--n", type=int, default=100)
    parser.add_argument("--seed", type=int, default=SEED)
    parser.add_argument("--restart", action="store_true",
                        help="discard prior progress instead of resuming")
    args = parser.parse_args()

    print(cfg.describe())
    parquet_dir = cfg.subdir("parquet")
    scratch_dir = cfg.subdir("scratch")
    manifest_dir = cfg.subdir("manifests")
    cfg.require_free_space(parquet_dir)

    source = puller.get_json(f"{puller.API}/sources/{UHC_SLUG}")
    month = source.get("selectedMonth", "")
    frame = build_frame(source.get("files", []))
    print(f"[FRAME] month={month} (API exposes current month only) "
          f"in_network={len(frame):,}")

    bands = collections.Counter(f["size_band"] for f in frame)
    families = collections.Counter(f["file_stem_family"] for f in frame)
    print(f"[FRAME] size bands: {dict(sorted(bands.items()))}")
    print(f"[FRAME] stem families: {len(families):,}")

    with open(os.path.join(manifest_dir, "uhc_sampling_frame.csv"),
              "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(frame[0].keys()))
        writer.writeheader()
        writer.writerows(frame)

    sample = stratified_sample(frame, args.n, args.seed)
    print(f"[SAMPLE] n={len(sample)} seed={args.seed}")
    print(f"[SAMPLE] bands: "
          f"{dict(sorted(collections.Counter(f['size_band'] for f in sample).items()))}")

    entity_types = builder.load_entity_types(parquet_dir)
    print(f"[NPPES] entity-type lookup: {len(entity_types):,} NPIs")

    per_file_path = os.path.join(manifest_dir, "uhc_sample_per_file.csv")
    membership_path = os.path.join(manifest_dir, "uhc_sample_membership.csv")

    # RESUME: a run interrupted at file 99 must not lose 99 files of work.
    # Completed positions are read back and skipped, and every file's results
    # are appended immediately rather than held until the end.
    done_positions, seen, pair_index = set(), set(), {}
    if os.path.exists(per_file_path) and not args.restart:
        with open(per_file_path) as handle:
            for row in csv.DictReader(handle):
                if row.get("parse_status") == "parsed":
                    done_positions.add(int(row["sample_position"]))
        print(f"[RESUME] {len(done_positions)} file(s) already complete")

    if args.restart:
        for path in (per_file_path, membership_path):
            if os.path.exists(path):
                os.remove(path)

    def append_csv(path, columns, rows):
        fresh = (not os.path.exists(path)) or os.path.getsize(path) == 0
        with open(path, "a", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=columns)
            if fresh:
                writer.writeheader()
            for row in rows:
                writer.writerow({c: row.get(c, "") for c in columns})

    PER_FILE_COLUMNS = ["sample_position", "file_id", "file_name",
                        "file_stem_family", "size_band", "compressed_size",
                        "source_url", "source_month", "num_parts_available",
                        "parse_status", "prefix_mb", "raw_bytes",
                        "occurrences", "stored_rows", "pairs_in_file",
                        "new_pairs", "cumulative_pairs", "distinct_npis",
                        "distinct_billing_ids", "class_ein",
                        "class_organization_npi", "class_self_billing_individual",
                        "class_ambiguous_individual_npi_anchor",
                        "class_unresolved_npi", "class_unknown_id_type",
                        "elapsed_seconds"]

    # Rebuild `seen` from prior membership so cumulative counts stay correct.
    if done_positions and os.path.exists(membership_path):
        with open(membership_path) as handle:
            reader = csv.reader(handle)
            next(reader, None)
            for row in reader:
                pair_index.setdefault(row[0], len(pair_index))
        print(f"[RESUME] {len(pair_index):,} pairs carried forward")

    per_file, membership = [], []
    run_start = time.time()

    for position, entry in enumerate(sample, start=1):
        if position in done_positions:
            continue
        cfg.verify_root_alive()          # fail fast if the volume remounted
        file_start = time.time()
        references, status = acquire_and_parse(entry, scratch_dir, entity_types)
        row = {**entry, **status, "sample_position": position,
               "occurrences": 0, "stored_rows": 0, "pairs_in_file": 0,
               "new_pairs": 0, "cumulative_pairs": len(seen),
               "distinct_npis": 0, "distinct_billing_ids": 0}

        if references is None:
            row["elapsed_seconds"] = round(time.time() - file_start, 1)
            append_csv(per_file_path, PER_FILE_COLUMNS, [row])
            per_file.append(row)
            print(f"  [{position:>3}] {status['parse_status']:<42} "
                  f"{entry['file_name'][:44]}", flush=True)
            continue

        relationships, occurrences = {}, 0
        for reference in references:
            name = reference.get("network_name")
            name = "|".join(name) if isinstance(name, list) else (name or "")
            for group in (reference.get("provider_groups") or []):
                tin = group.get("tin") or {}
                tin_type = (tin.get("type") or "").lower()
                tin_value = puller.norm_tin(tin.get("value"), tin_type)
                if not tin_value:
                    continue
                members = {puller.norm_npi(x) for x in (group.get("npi") or [])}
                members.discard("")
                billing_class, entity, is_member, reason = \
                    builder.classify_billing_id(tin_type, tin_value, members,
                                                entity_types)
                for npi in members:
                    occurrences += 1
                    relationships[(npi, tin_type, tin_value, name)] = billing_class

        pairs = {(k[0], k[1], k[2]) for k in relationships}
        new_pairs = pairs - seen
        seen |= pairs

        new_membership = []
        for pair in pairs:
            key = hashlib.blake2b("|".join(pair).encode(), digest_size=8).hexdigest()
            index = pair_index.setdefault(key, len(pair_index))
            new_membership.append((index, position - 1))
        membership.extend(new_membership)

        classes = collections.Counter(relationships.values())
        row.update({
            "occurrences": occurrences,
            "stored_rows": len(relationships),
            "pairs_in_file": len(pairs),
            "new_pairs": len(new_pairs),
            "cumulative_pairs": len(seen),
            "distinct_npis": len({p[0] for p in pairs}),
            "distinct_billing_ids": len({p[2] for p in pairs}),
            **{f"class_{k}": v for k, v in classes.items()},
        })
        row["elapsed_seconds"] = round(time.time() - file_start, 1)
        append_csv(per_file_path, PER_FILE_COLUMNS, [row])
        append_csv(membership_path, ["pair_index", "file_position"],
                   [{"pair_index": p, "file_position": q} for p, q in new_membership])
        per_file.append(row)
        print(f"  [{position:>3}] {occurrences:>10,} occ  {len(pairs):>9,} pairs  "
              f"{len(new_pairs):>9,} new  {len(seen):>10,} cum  "
              f"{row['elapsed_seconds']:>6.1f}s  {entry['file_name'][:30]}", flush=True)

    print(f"\n[SAMPLE] wall-clock: {time.time() - run_start:.0f}s "
          f"({(time.time() - run_start) / 60:.1f} min)")
    print(f"[SAMPLE] cumulative unique npi-identifier pairs: {len(seen):,}")
    print(f"[SAMPLE] membership rows for permutation analysis: {len(membership):,}")
    print(f"[SAMPLE] manifests: {manifest_dir}")


if __name__ == "__main__":
    sys.exit(main())
