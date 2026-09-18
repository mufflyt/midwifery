#!/usr/bin/env python3
"""
Build the deduplicated NPI <-> billing-identifier tables from raw MRF payloads.

REPLACES the observation-grain extraction that produced 59 GB.

THE DEFECT THIS FIXES

The previous extractor wrote one row per (npi, tin) OCCURRENCE, carrying the
full source URL, file stem, network name and business name on every row.
A provider group repeats across many provider_reference entries, so Anthem's
Colorado files produced 105,630,684 rows from 58,921 distinct NPIs and 8,944
distinct billing identifiers -- about 200x duplication, 59 GB, and a full disk.

Three changes:

  1. DEDUPLICATE DURING EXTRACTION, not after. Rows enter a set keyed on the
     relationship grain as they are parsed, so the 100-million-row intermediate
     never exists at any point.

  2. NORMALISE THE METADATA OUT. Long strings live once in their own table and
     are referenced by key:

       fact_relationship  npi | tin_type | tin_value | payer | network_name |
                          source_month | source_file_id
       dim_file           source_file_id | stem | url | payer | month | sha256
       dim_tin            tin_type | tin_value | business_name

  3. PARQUET, NOT CSV. Columnar and compressed; this shape typically lands
     10-20x smaller.

PROJECT A: clinician NPI <-> BILLING/CONTRACTING ENTITY IDENTIFIER.

Not an EIN crosswalk. The TiC schema allows tin.type to be "ein" or "npi", and
payers differ completely: Kaiser publishes both, Anthem publishes NO EINs at
all. An EIN-only product would silently drop an entire major payer.

`tin_type == "npi"` is NOT a synonym for self-billing. NPPES Entity Type Code
decides: 7,576 of Kaiser's npi-typed identifiers are Entity Type 2
organisations that list themselves as their own sole member, and a member-count
heuristic misclassified every one of them as an individual.

A billing identifier says who BILLS. It does not establish employment,
ownership, independent practice, or health-system affiliation.

Usage:
    accessmrf_06_build_relationships.py --reparse            # all payer dirs
    accessmrf_06_build_relationships.py --reparse --payer-dir kaiser-...
"""

import argparse
import collections
import csv
import hashlib
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import accessmrf_config as cfg                                    # noqa: E402


def _load(name):
    spec = importlib.util.spec_from_file_location(
        name.replace(".py", ""), os.path.join(HERE, name))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


puller = _load("accessmrf_03_pull_provider_refs.py")

LOCAL_RAW = os.path.join("data", "raw", "accessmrf")

# NPPES Entity Type Code is the AUTHORITY on what a billing NPI is:
# 1 = individual, 2 = organization (CMS data-dissemination code values).
# Member count is evidence, never the classifier -- a Type 1 NPI anchoring
# several clinicians is a payer anomaly worth preserving, not an organisation
# to be inferred into existence.
ENTITY_INDIVIDUAL = "1"
ENTITY_ORGANIZATION = "2"


def load_entity_types(parquet_dir):
    """npi -> NPPES Entity Type Code, from the prebuilt lookup."""
    import subprocess
    path = os.path.join(parquet_dir, "dim_nppes_entity_type.parquet")
    if not os.path.exists(path):
        print(f"   WARNING: {path} missing; every npi-typed identifier will "
              f"classify as unresolved_npi")
        return {}
    out = subprocess.run(
        ["duckdb", "-noheader", "-list", "-c",
         f"SELECT npi || ',' || coalesce(nppes_entity_type,'') "
         f"FROM read_parquet('{path}')"],
        capture_output=True, text=True, check=True).stdout
    lookup = {}
    for line in out.splitlines():
        npi, _, entity = line.partition(",")
        if npi:
            lookup[npi] = entity
    return lookup


def classify_billing_id(raw_type, raw_value, member_npis, entity_types):
    """Return (billing_id_class, nppes_entity_type, is_member, reason).

    Deliberately does NOT infer employer, ownership, independent practice or
    health-system affiliation. A billing identifier says who bills, which is
    not the same as who employs or owns -- payers are documented putting
    organizational NPIs, and sometimes insurer identifiers, in this position.
    """
    if raw_type == "ein":
        return "ein", "", False, "tin.type=ein"

    if raw_type != "npi":
        return "unknown_id_type", "", False, f"tin.type={raw_type or 'missing'}"

    entity = entity_types.get(raw_value, "")
    is_member = raw_value in member_npis

    if entity == ENTITY_ORGANIZATION:
        return "organization_npi", entity, is_member, "nppes_entity_type=2"

    if entity == ENTITY_INDIVIDUAL:
        if is_member and len(member_npis) == 1:
            return ("self_billing_individual", entity, True,
                    "nppes_entity_type=1 and billing npi is sole member")
        return ("ambiguous_individual_npi_anchor", entity, is_member,
                f"nppes_entity_type=1 with {len(member_npis)} members")

    return "unresolved_npi", "", is_member, "npi absent from NPPES lookup"


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_deduplicated(path, payer_group, payer_source, source_month,
                         entity_types):
    """Parse one payload into deduplicated relationship + tin rows.

    Returns (relationships, tins, stats). `relationships` is already a set, so
    a payer that repeats a provider group 200 times costs 200 set lookups
    rather than 200 stored rows.
    """
    references = puller.stream_provider_references(path)
    shape = "provider_references"

    if references is None:
        # Inline shape: provider_groups nested under negotiated_rates, with no
        # network_name and no business_name. Only parsed when small enough --
        # walking a multi-GB rate body to reach them is not worth it here.
        size = os.path.getsize(path)
        if size > 300_000_000:
            return set(), set(), {"shape": "inline_too_large", "skipped": True}
        document = puller.load_mrf(path)
        references = [{"network_name": "", "provider_groups": groups}
                      for item in (document.get("in_network") or [])
                      for rate in (item.get("negotiated_rates") or [])
                      for groups in [rate.get("provider_groups") or []]]
        shape = "inline_provider_groups"

    relationships = {}
    tins = set()
    occurrences = 0

    for reference in references:
        name = reference.get("network_name")
        name = "|".join(name) if isinstance(name, list) else (name or "")
        for group in (reference.get("provider_groups") or []):
            tin = group.get("tin") or {}
            tin_type = (tin.get("type") or "").lower()
            tin_value = puller.norm_tin(tin.get("value"), tin_type)
            if not tin_value:
                continue
            business = " ".join((tin.get("business_name") or "").upper().split())
            if business:
                tins.add((tin_type, tin_value, business))

            members = {puller.norm_npi(x) for x in (group.get("npi") or [])}
            members.discard("")
            billing_class, entity, is_member, reason = classify_billing_id(
                tin_type, tin_value, members, entity_types)

            for npi in members:
                occurrences += 1
                # KEY = the relationship itself. Evidence fields are aggregated
                # onto it, never part of it: the same clinician-identifier pair
                # appears in groups of differing composition, so keying on
                # member_count and billing_npi_is_member inflated Anthem's row
                # count by 37% with rows that are not distinct relationships.
                key = (npi, tin_type, tin_value, payer_group, name,
                       source_month)
                previous = relationships.get(key)
                size = len(members)
                if previous is None:
                    relationships[key] = [billing_class, entity, is_member,
                                          size, size, reason]
                else:
                    previous[2] = previous[2] or is_member
                    previous[3] = min(previous[3], size)
                    previous[4] = max(previous[4], size)
            if len(relationships) > cfg.MAX_ROWS_PER_FILE:
                raise RuntimeError(
                    f"{os.path.basename(path)} exceeded "
                    f"{cfg.MAX_ROWS_PER_FILE:,} distinct relationships; "
                    f"aborting before writing.")

    return relationships, tins, {
        "shape": shape,
        "occurrences": occurrences,
        "relationships": len(relationships),
        "duplication_factor": round(occurrences / max(len(relationships), 1), 1),
        "skipped": False,
    }


def relationship_hashes(relationships, tins):
    """Primary (label-free) and secondary (labelled) semantic fingerprints.

    The primary hash deliberately excludes business_name: the same EIN is
    written "UCHEALTH", "UC HEALTH" or under a subsidiary name in different
    files, and letting that vary would split identical crosswalks and
    understate duplication -- the one number this measures.
    """
    plain = sorted({(r[0], r[1], r[2]) for r in relationships})
    labels = {(t[0], t[1]): t[2] for t in tins}
    labelled = sorted({(r[0], r[1], r[2], labels.get((r[1], r[2]), ""))
                       for r in relationships})
    return (
        hashlib.sha256("\n".join("|".join(r) for r in plain).encode()).hexdigest(),
        hashlib.sha256("\n".join("|".join(r) for r in labelled).encode()).hexdigest(),
    )


def write_parquet(rows, columns, destination, scratch_dir):
    """CSV -> Parquet via duckdb (pyarrow is not installed here)."""
    import subprocess
    if not rows:
        return 0
    os.makedirs(scratch_dir, exist_ok=True)
    staging = os.path.join(scratch_dir, os.path.basename(destination) + ".csv")
    with open(staging, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(columns)
        writer.writerows(rows)
    subprocess.run(
        ["duckdb", "-c",
         f"COPY (SELECT * FROM read_csv('{staging}', all_varchar=true)) "
         f"TO '{destination}' (FORMAT PARQUET, COMPRESSION ZSTD);"],
        check=True, capture_output=True)
    os.remove(staging)
    return os.path.getsize(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--reparse", action="store_true",
                        help="reparse payloads already on disk; never downloads")
    parser.add_argument("--payer-dir", default=None)
    parser.add_argument("--raw-dir", default=LOCAL_RAW,
                        help="where the already-downloaded payloads are")
    args = parser.parse_args()

    print(cfg.describe())
    parquet_dir = cfg.subdir("parquet")
    manifest_dir = cfg.subdir("manifests")
    scratch_dir = cfg.subdir("scratch")
    cfg.require_free_space(parquet_dir)

    entity_types = load_entity_types(parquet_dir)
    print(f"[NPPES] entity-type lookup: {len(entity_types):,} NPIs")

    payer_dirs = ([args.payer_dir] if args.payer_dir
                  else sorted(d for d in os.listdir(args.raw_dir)
                              if os.path.isdir(os.path.join(args.raw_dir, d))))

    # Payer identity is carried by the directory name, which is the AccessMRF
    # slug; the human-readable group comes from the existing manifest.
    payer_by_dir = {}
    old_manifest = os.path.join("artifacts", "accessmrf", "colorado_file_manifest.csv")
    if os.path.exists(old_manifest):
        with open(old_manifest) as handle:
            for row in csv.DictReader(handle):
                local = row.get("local_path") or ""
                if local:
                    payer_by_dir[os.path.basename(os.path.dirname(local))] = (
                        row.get("payer_group", ""), row.get("payer_source", ""))

    all_relationships, all_tins, file_rows, hash_rows = {}, set(), [], []
    seen_pairs, discovery_rows = set(), []

    for payer_dir in payer_dirs:
        directory = os.path.join(args.raw_dir, payer_dir)
        payer_group, payer_source = payer_by_dir.get(payer_dir, (payer_dir, payer_dir))
        names = sorted(n for n in os.listdir(directory)
                       if n.endswith(".json") or n.endswith(".json.gz"))
        print(f"\n[{payer_group}] {len(names)} payload(s) in {payer_dir[:40]}")

        for name in names:
            path = os.path.join(directory, name)
            try:
                rels, tins, stats = extract_deduplicated(
                    path, payer_group, payer_source, "", entity_types)
            except Exception as exc:                          # noqa: BLE001
                print(f"   ERR  {name[:52]}: {type(exc).__name__}: {exc}")
                continue

            if stats.get("skipped"):
                print(f"   SKIP {name[:52]} ({stats['shape']})")
                continue

            plain_hash, labelled_hash = relationship_hashes(rels, tins)
            file_id = hashlib.sha256(path.encode()).hexdigest()[:16]

            # Marginal discovery: how many npi-identifier pairs this file adds
            # that no earlier file in this run had. This is the saturation
            # curve, measured per file rather than inferred from file counts.
            pairs_here = {(k[0], k[1], k[2]) for k in rels}
            new_pairs = pairs_here - seen_pairs
            seen_pairs |= pairs_here
            discovery_rows.append([file_id, name, payer_group,
                                   stats["occurrences"], len(pairs_here),
                                   len(new_pairs), len(seen_pairs)])

            for key, evidence in rels.items():
                prior = all_relationships.get(key)
                if prior is None:
                    all_relationships[key] = evidence
                else:
                    prior[2] = prior[2] or evidence[2]
                    prior[3] = min(prior[3], evidence[3])
                    prior[4] = max(prior[4], evidence[4])
            all_tins |= tins
            file_rows.append([file_id, name, payer_group, payer_source,
                              os.path.getsize(path), sha256_file(path),
                              stats["shape"]])
            hash_rows.append([file_id, name, payer_group,
                              plain_hash, labelled_hash,
                              stats["occurrences"], stats["relationships"],
                              stats["duplication_factor"]])

            print(f"   {name[:46]:<46} {stats['occurrences']:>10,} occ -> "
                  f"{stats['relationships']:>9,} rel  ({stats['duplication_factor']}x)")

    rel_rows = [list(k) + [e[0], e[1], str(e[2]).upper(), str(e[3]),
                           str(e[4]), e[5]]
                for k, e in sorted(all_relationships.items())]
    tin_rows = sorted(all_tins)

    # PARTITIONED BY PAYER. A single filename per table meant the Anthem run
    # silently overwrote Kaiser's fact_relationship.parquet.
    tag = (args.payer_dir or "all")[:48]
    part = os.path.join(parquet_dir, f"payer={tag}")
    os.makedirs(part, exist_ok=True)

    sizes = {
        f"{tag}/fact_relationship.parquet": write_parquet(
            rel_rows,
            ["npi", "billing_id_type_raw", "billing_id_value_raw",
             "payer_group", "network_name", "source_month", "billing_id_class",
             "nppes_entity_type", "billing_npi_is_member",
             "provider_group_member_count_min",
             "provider_group_member_count_max", "classification_reason"],
            os.path.join(part, "fact_relationship.parquet"), scratch_dir),
        f"{tag}/dim_tin.parquet": write_parquet(
            tin_rows, ["billing_id_type_raw", "billing_id_value_raw",
                       "business_name"],
            os.path.join(part, "dim_tin.parquet"), scratch_dir),
        f"{tag}/dim_file.parquet": write_parquet(
            file_rows,
            ["source_file_id", "file_stem", "payer_group", "payer_source",
             "bytes", "sha256", "shape"],
            os.path.join(part, "dim_file.parquet"), scratch_dir),
        f"{tag}/file_discovery_curve.parquet": write_parquet(
            discovery_rows,
            ["source_file_id", "file_stem", "payer_group", "occurrences",
             "pairs_in_file", "new_pairs", "cumulative_pairs"],
            os.path.join(part, "file_discovery_curve.parquet"), scratch_dir),
        f"{tag}/file_relationship_hashes.parquet": write_parquet(
            hash_rows,
            ["source_file_id", "file_stem", "payer_group", "relationship_hash",
             "labeled_relationship_hash", "occurrences", "relationships",
             "duplication_factor"],
            os.path.join(part, "file_relationship_hashes.parquet"),
            scratch_dir),
    }

    # Reported per payer AND in total. Compressed file size alone hides
    # whether the collapse came from deduplication or merely from Parquet, so
    # the occurrence count and the duplication factor are reported beside it.
    by_payer = collections.defaultdict(
        lambda: {"occ": 0, "rel": set(), "stored": set(), "npi": set(),
                 "ein": set(), "npi_ein": set(), "org_npi": set(),
                 "npi_org": set()})
    for row in hash_rows:
        by_payer[row[2]]["occ"] += row[5]
    # Indexed, not unpacked: the row widened from 6 to 11 fields when the
    # classification columns were added and positional unpacking broke.
    for row in rel_rows:
        npi, tin_type, tin_value, payer = row[0], row[1], row[2], row[3]
        billing_class = row[6]
        bucket = by_payer[payer]
        bucket["stored"].add(tuple(row[:6]))
        bucket["rel"].add((npi, tin_type, tin_value))
        bucket["npi"].add(npi)
        if tin_type == "ein":
            bucket["ein"].add(tin_value)
            bucket["npi_ein"].add((npi, tin_value))
        if billing_class == "organization_npi":
            bucket["org_npi"].add(tin_value)
            bucket["npi_org"].add((npi, tin_value))

    total_bytes = sum(sizes.values())

    print("\n" + "=" * 92)
    print("DEDUPLICATED RELATIONSHIP TABLES")
    print("=" * 92)
    # TWO GRAINS, NAMED DIFFERENTLY ON PURPOSE. `rel_rows` counts the stored
    # grain (npi|tin_type|tin_value|payer|network|month); `npi_id` counts
    # distinct NPI-to-identifier pairs, collapsing network and month. Kaiser is
    # 2,392,207 stored rows but only 808,979 distinct pairs, because one
    # provider sits in several networks. Reporting both under the word
    # "relationships" made the same payer look like 1.1x and 3.1x duplication
    # in one table.
    header = (f"{'payer':<22}{'occurrences':>13}{'stored rows':>13}"
              f"{'npi-id pairs':>14}{'NPI-EIN':>10}{'NPIs':>9}{'EINs':>8}"
              f"{'dup(row)':>10}{'dup(pair)':>10}")
    print(header)
    for payer, bucket in sorted(by_payer.items()):
        stored = len(bucket["stored"])
        pairs = len(bucket["rel"])
        print(f"{payer[:22]:<22}{bucket['occ']:>13,}{stored:>13,}{pairs:>14,}"
              f"{len(bucket['npi_ein']):>10,}{len(bucket['npi']):>9,}"
              f"{len(bucket['ein']):>8,}"
              f"{bucket['occ'] / max(stored, 1):>9.1f}x"
              f"{bucket['occ'] / max(pairs, 1):>9.1f}x")

    total_occ = sum(b["occ"] for b in by_payer.values())
    by_type = collections.Counter(r[1] for r in rel_rows)
    eins = {r[2] for r in rel_rows if r[1] == "ein"}
    npis = {r[0] for r in rel_rows}
    npi_ein = {(r[0], r[2]) for r in rel_rows if r[1] == "ein"}

    print("-" * 92)
    npi_id = {(r[0], r[1], r[2]) for r in rel_rows}
    org_npis = {r[2] for r in rel_rows if r[6] == "organization_npi"}
    npi_org_pairs = {(r[0], r[2]) for r in rel_rows if r[6] == "organization_npi"}
    by_class = collections.Counter()
    class_pairs = collections.defaultdict(set)
    for r in rel_rows:
        by_class[r[6]] += 1
        class_pairs[r[6]].add((r[0], r[2]))
    print(f"raw occurrences                  {total_occ:>14,}")
    print(f"distinct stored rows             {len(rel_rows):>14,}"
          f"   (npi|tin_type|tin_value|payer|network|month)")
    print(f"distinct npi-identifier pairs    {len(npi_id):>14,}"
          f"   (network/month collapsed)")
    print(f"  tin_type = ein                 {by_type.get('ein', 0):>14,}")
    print(f"  tin_type = npi                 {by_type.get('npi', 0):>14,}"
          f"   (may be organisation OR self-billing; see class table)")
    print(f"distinct NPI-EIN relationships   {len(npi_ein):>14,}")
    print(f"distinct NPIs                    {len(npis):>14,}")
    print(f"distinct EINs                    {len(eins):>14,}")
    print(f"distinct organization NPIs       {len(org_npis):>14,}")
    print(f"clinician-organization NPI pairs {len(npi_org_pairs):>14,}")
    print(f"duplication factor, stored rows  {total_occ / max(len(rel_rows), 1):>13.1f}x")
    print(f"duplication factor, npi-id pairs {total_occ / max(len(npi_id), 1):>13.1f}x")
    print(f"dim_tin rows                     {len(tin_rows):>14,}")
    print("-" * 92)
    print("clinician <-> billing/contracting entity, by identifier class")
    print(f"{'billing_id_class':<36}{'stored rows':>14}{'unique pairs':>15}"
          f"{'distinct ids':>14}")
    for name in ("ein", "organization_npi", "self_billing_individual",
                 "ambiguous_individual_npi_anchor", "unresolved_npi",
                 "unknown_id_type"):
        if not by_class.get(name):
            continue
        ids = {p[1] for p in class_pairs[name]}
        print(f"{name:<36}{by_class[name]:>14,}{len(class_pairs[name]):>15,}"
              f"{len(ids):>14,}")
    if discovery_rows:
        print("-" * 92)
        print("marginal discovery per file (npi-identifier pairs)")
        print(f"{'file':<50}{'occurrences':>14}{'new pairs':>12}{'cumulative':>13}")
        for row in discovery_rows:
            print(f"{row[1][:50]:<50}{row[3]:>14,}{row[5]:>12,}{row[6]:>13,}")
    print("-" * 92)
    for name, size in sizes.items():
        print(f"{name:<44}{size / 1e6:>10.2f} MB")
    print(f"{'TOTAL PARQUET BYTES':<44}{total_bytes / 1e6:>10.2f} MB"
          f"   ({total_bytes:,} bytes)")
    print("-" * 92)
    print(f"parquet:   {parquet_dir}")
    print(f"manifests: {manifest_dir}")
    print("=" * 92)


if __name__ == "__main__":
    sys.exit(main())
