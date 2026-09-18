#!/usr/bin/env python3
"""
AccessMRF Colorado pilot, step 5: how much of the file explosion is duplication?

Metadata only. NOTHING is downloaded here except the per-payer source listing,
which is one API call each. The question this answers has to be settled before
any large acquisition is justified:

    Do a payer's tens of thousands of indexed files collapse to a much smaller
    number of distinct downloadable objects, and do those objects collapse
    further to a small number of distinct provider-group structures?

WHY THIS REPLACED FILENAME/STATE TARGETING

Selecting files by state-coded filename turned out to be a per-payer craft
rather than a method. Kaiser writes KFHP_CO-COMMERCIAL, Anthem writes
CO_CBPLMED0000, Cigna writes ..._colorado-cpop_... -- three payers, three
conventions, and a loose regex silently matched TOBACCO-CO-INC while missing
^CO_ entirely. Worse, a Kaiser file labelled Colorado carries providers from
every Kaiser region, so the label does not even mean what it appears to.

TWO COUNTS THAT ARE EASY TO CONFUSE

  files_indexed_all_months   what the sources index advertises, summed over
                             every monthly vintage it holds
  files_current_month        what one vintage actually contains

UnitedHealthcare advertises 274,511 and holds 7,845 in the current month --
a 35x difference that made the acquisition look intractable when it is not.
Only the current-month figure describes a single-vintage pull.

The provider-reference hash measures the thing that actually matters for
acquisition cost: two files whose provider_references block hashes identically
contribute exactly the same NPI-TIN information, so one of them is free.
"""

import collections
import csv
import hashlib
import json
import os
import ssl
import sys
import urllib.request

API = "https://www.accessmrf.com/api"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def _ssl_context():
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SSL_CONTEXT = _ssl_context()

ARTIFACT_DIR = os.path.join("artifacts", "accessmrf")
RAW_DIR = os.path.join("data", "raw", "accessmrf")

# The five payer groups covering 98.2% of Colorado insured commercial
# life-years, with the AccessMRF slugs each maps to.
PAYERS = [
    ("KAISER FOUNDATION GRP", ["kaiser-permanente-05b5228ef76d4c51875004e4f254aede"]),
    ("Elevance Hlth Inc Grp", ["anthem-f67482b5a3054e7aa86dfca9e28e5a96"]),
    ("UNITEDHEALTH GRP", ["united-healthcare-3e137223de3b464c9de76a5887a32757"]),
    ("Cigna Hlth Grp", ["cigna-ce48aa3f8f2f4f9aa000415ff0dcabce"]),
    ("CVS Health Group", [
        "aetna-cvs-fully-insured-53949a6555d545e0add29dd55de15bf1",
        "aetna-cvs-self-insured-0885177a0eed4bfdace74eb8f565d119",
        "aetna-cvs-health-insurance-marketplace-e7f09d3cbd684a6c8bb19",
    ]),
]


def get_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=300, context=SSL_CONTEXT) as response:
        return json.load(response)


def index_totals():
    """files_indexed across ALL months, from the top-level sources index."""
    sources = get_json(f"{API}/sources")["sources"]
    return {s["slug"]: s for s in sources}


# A month is not "complete" merely because the calendar has moved past it:
# AccessMRF keeps discovering files for a month after it ends, so on 16 Sep the
# August index may still be filling. The API exposes no per-month file-count
# history, so stabilisation cannot be demonstrated from metadata alone. The
# audit therefore uses a COMMON month, at least LAG_MONTHS behind the current
# one, for all payer-to-payer comparison, and reports each payer's later months
# separately rather than comparing on them.
LAG_MONTHS = 2
FALLBACK_COMMON_MONTH = "2026-07-01"


def _shift_month(year, month, back):
    total = year * 12 + (month - 1) - back
    return f"{total // 12:04d}-{total % 12 + 1:02d}-01"


def safe_common_month(month_sets, today=None):
    """Newest month present for EVERY payer and at least LAG_MONTHS old."""
    import datetime
    today = today or datetime.date.today()
    ceiling = _shift_month(today.year, today.month, LAG_MONTHS)

    common = set.intersection(*[set(m) for m in month_sets if m]) if month_sets else set()
    eligible = sorted(m for m in common if m <= ceiling)
    if eligible:
        return eligible[-1], "common_lagged"
    if common:
        return sorted(common)[-1], "common_but_not_lagged"
    return FALLBACK_COMMON_MONTH, "fallback_no_common_month"


def audit_payer(payer_group, slugs, index, pinned_month=None):
    files, months, missing = [], set(), []
    per_slug_month = {}

    for slug in slugs:
        try:
            detail = get_json(f"{API}/sources/{slug}")
        except Exception as exc:                       # noqa: BLE001
            missing.append(f"{slug}: {type(exc).__name__}")
            continue
        slug_months = detail.get("months") or []
        months.update(slug_months)

        # THE API SILENTLY IGNORES ?month=. Verified against the live service:
        # month, selectedMonth, date and fileDate all return HTTP 200 with the
        # CURRENT month's files and no warning. Code that requested July and
        # stamped "July" on the result produced September data labelled July --
        # a silent success, undetectable downstream.
        #
        # No server-side month filtering is attempted. Files are filtered
        # CLIENT-SIDE on the month the API reports for each file, and the
        # requested month is never written out as though it were observed.
        per_slug_month[slug] = pinned_month

        for entry in detail.get("files", []):
            observed = (entry.get("fileDate") or "").strip()
            if not observed:
                # Fail closed: a file whose month cannot be observed is never
                # assigned the requested one.
                missing.append(f"{slug}: file {entry.get('fileId', '?')} has "
                               f"no fileDate; excluded")
                continue
            if pinned_month and observed != pinned_month:
                continue
            entry["_slug"] = slug
            entry["_observed_month"] = observed
            files.append(entry)

    # Post-filter assertion: nothing disagreeing with the request survives.
    if pinned_month:
        wrong = {f.get("_observed_month") for f in files
                 if f.get("_observed_month") != pinned_month}
        if wrong:
            raise MonthMismatch(
                f"{payer_group}: requested {pinned_month} but files carry "
                f"{sorted(wrong)}. The API ignores ?month=; refusing to label "
                f"these as {pinned_month}.")

    indexed_all_months = sum(
        (index.get(s, {}).get("numFiles") or 0) for s in slugs
    )

    in_network = [f for f in files if f.get("fileSchema") == "IN_NETWORK"]
    allowed = [f for f in files if f.get("fileSchema") == "ALLOWED_AMOUNT"]

    urls = [f.get("url", "") for f in files]
    stems = [f.get("fileStem", "") for f in files]
    url_counts = collections.Counter(urls)

    return {
        "payer_group": payer_group,
        "accessmrf_sources": len(slugs),
        "files_indexed_all_months": indexed_all_months,
        "latest_available_month": max(months) if months else "",
        "requested_month": pinned_month or "",
        "observed_source_month": "|".join(sorted(
            {f.get("_observed_month", "") for f in files})) or "(none)",
        "comparison_month": "|".join(sorted({v for v in per_slug_month.values() if v})),
        "months_newer_than_comparison": len([m for m in months
                                             if m > (max(per_slug_month.values()) or "")]),
        "files_comparison_month": len(files),
        "months_available": len(months),
        "in_network_files_comparison_month": len(in_network),
        "allowed_amount_files_comparison_month": len(allowed),
        "unique_download_urls": len(set(urls)),
        "unique_file_stems": len(set(stems)),
        "unique_in_network_stems": len({f.get("fileStem", "") for f in in_network}),
        "files_sharing_a_url": sum(n for n in url_counts.values() if n > 1),
        "url_duplication_ratio": round(len(files) / max(len(set(urls)), 1), 2),
        "stem_duplication_ratio": round(len(files) / max(len(set(stems)), 1), 2),
        "index_vs_month_ratio": round(indexed_all_months / max(len(files), 1), 1),
        "errors": "; ".join(missing) or "",
    }


def relationship_rows(references, puller, with_label):
    """The set of provider relationships a file asserts.

    `with_label=False` gives the PRIMARY fingerprint:

        npi | tin_type | tin_value

    Business name is excluded on purpose. The same EIN is written "UCHEALTH",
    "UC HEALTH", or under a legal subsidiary name in different files, and
    letting that vary would split otherwise identical crosswalks and silently
    understate duplication -- which is the one number this audit exists to
    measure.

    `with_label=True` adds the normalised business name, so the two hashes can
    be differenced to isolate pure labelling disagreement on an identical
    relationship set.
    """
    out = set()
    for reference in references:
        for group in (reference.get("provider_groups") or []):
            tin = group.get("tin") or {}
            tin_type = (tin.get("type") or "").lower()
            tin_value = puller.norm_tin(tin.get("value"), tin_type)
            if not tin_value:
                continue
            business = " ".join((tin.get("business_name") or "").upper().split())
            for raw_npi in (group.get("npi") or []):
                npi = puller.norm_npi(raw_npi)
                if not npi:
                    continue
                out.add((npi, tin_type, tin_value, business) if with_label
                        else (npi, tin_type, tin_value))
    return out


def normalized_relationships(references, puller):
    """The semantic fingerprint: the SET of provider relationships a file asserts.

    A byte hash of the JSON block answers "are these files identical", which is
    not the question. Two payers -- or two vintages of one payer -- can publish
    the same NPI-TIN relationships in a different order, with different
    provider_group_ids, different whitespace, or the groups split differently,
    and a raw hash calls those distinct when they carry identical information.

    So the block is reduced to a deterministic set of

        npi | tin_value | tin_type | business_name

    rows, deduplicated and sorted, then hashed. Both hashes are kept: the raw
    one shows byte-level churn between vintages, the normalized one is the
    duplication measure that matters for the NPI-to-billing-organization build.

    business_name is upper-cased and whitespace-collapsed only. It is NOT
    dropped, because the same EIN can appear under different names and that
    disagreement is itself worth seeing -- but it is normalised so trivial
    spacing differences do not split an otherwise identical structure.
    """
    out = set()
    for reference in references:
        for group in (reference.get("provider_groups") or []):
            tin = group.get("tin") or {}
            tin_type = (tin.get("type") or "").lower()
            tin_value = puller.norm_tin(tin.get("value"), tin_type)
            business = " ".join((tin.get("business_name") or "").upper().split())
            if not tin_value:
                continue
            for raw_npi in (group.get("npi") or []):
                npi = puller.norm_npi(raw_npi)
                if npi:
                    out.add((npi, tin_value, tin_type, business))
    return out


def hash_downloaded_provider_references():
    """Hash the provider_references block of every file already on disk.

    Two files with the same hash carry identical NPI-TIN content, so the second
    was wasted bandwidth. This is the empirical duplication ratio that decides
    whether acquisition should be organised around unique provider structures
    instead of around files.
    """
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "puller", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "accessmrf_03_pull_provider_refs.py"))
    puller = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(puller)

    rows = []
    for root, _dirs, names in os.walk(RAW_DIR):
        for name in sorted(names):
            if not (name.endswith(".json") or name.endswith(".json.gz")):
                continue
            path = os.path.join(root, name)
            try:
                references = puller.stream_provider_references(path)
            except Exception as exc:                   # noqa: BLE001
                rows.append({"path": path, "payer_dir": os.path.basename(root),
                             "status": f"error: {type(exc).__name__}",
                             "raw_provider_reference_hash": "",
                             "relationship_hash": "",
                             "labeled_relationship_hash": "",
                             "n_references": 0, "n_provider_groups": 0,
                             "n_relationships": 0, "n_distinct_npis": 0,
                             "n_distinct_eins": 0})
                continue

            if references is None:
                rows.append({"path": path, "payer_dir": os.path.basename(root),
                             "status": "no_provider_references",
                             "raw_provider_reference_hash": "",
                             "relationship_hash": "",
                             "labeled_relationship_hash": "",
                             "n_references": 0, "n_provider_groups": 0,
                             "n_relationships": 0, "n_distinct_npis": 0,
                             "n_distinct_eins": 0})
                continue

            raw_canonical = json.dumps(references, sort_keys=True,
                                       separators=(",", ":")).encode()

            plain = relationship_rows(references, puller, with_label=False)
            labeled = relationship_rows(references, puller, with_label=True)

            plain_blob = "\n".join("|".join(r) for r in sorted(plain)).encode()
            labeled_blob = "\n".join("|".join(r) for r in sorted(labeled)).encode()

            eins = {r[2] for r in plain if r[1] == "ein"}
            rows.append({
                "path": path,
                "payer_dir": os.path.basename(root),
                "status": "ok",
                "raw_provider_reference_hash": hashlib.sha256(raw_canonical).hexdigest(),
                "relationship_hash": hashlib.sha256(plain_blob).hexdigest(),
                "labeled_relationship_hash": hashlib.sha256(labeled_blob).hexdigest(),
                "n_references": len(references),
                "n_provider_groups": sum(
                    len(r.get("provider_groups") or []) for r in references),
                "n_relationships": len(plain),
                "n_distinct_npis": len({r[0] for r in plain}),
                "n_distinct_eins": len(eins),
            })
    return rows


def provenance_stamp():
    """Which code produced a row, and when the listing was read."""
    import datetime
    import subprocess
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        sha = subprocess.run(["git", "-C", here, "rev-parse", "--short", "HEAD"],
                             capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:                                   # noqa: BLE001
        sha = ""
    extractor = os.path.join(here, "accessmrf_03_pull_provider_refs.py")
    with open(extractor, "rb") as handle:
        code_sha = hashlib.sha256(handle.read()).hexdigest()[:16]
    return {
        "extraction_code_version": f"accessmrf_05+03:{code_sha}",
        "extractor_git_sha": sha,
        "source_listing_timestamp": datetime.datetime.now(
            datetime.timezone.utc).isoformat(timespec="seconds"),
    }


def main():
    os.makedirs(ARTIFACT_DIR, exist_ok=True)
    stamp = provenance_stamp()

    print("[INDEX] fetching top-level sources index")
    index = index_totals()

    print("[MONTH] resolving a safe common comparison month")
    month_sets = []
    for _payer_group, slugs in PAYERS:
        for slug in slugs:
            try:
                month_sets.append(get_json(f"{API}/sources/{slug}").get("months") or [])
            except Exception:                           # noqa: BLE001
                pass
    comparison_month, month_basis = safe_common_month(month_sets)
    print(f"[MONTH] comparison month = {comparison_month} ({month_basis})")

    audit = []
    for payer_group, slugs in PAYERS:
        print(f"[AUDIT] {payer_group}")
        row = audit_payer(payer_group, slugs, index, pinned_month=comparison_month)
        if row["files_comparison_month"] == 0:
            raise SystemExit(
                f"No files observed for {payer_group} in {comparison_month}. "
                f"The API exposes only the current month; either request the "
                f"current month or obtain historical vintages another way.")
        row["comparison_month_basis"] = month_basis
        row.update(stamp)
        audit.append(row)

    audit_path = os.path.join(ARTIFACT_DIR, "payer_file_duplication_audit.csv")
    with open(audit_path, "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(audit[0].keys()))
        writer.writeheader()
        writer.writerows(audit)

    print("\n[HASH] hashing provider_references of files already downloaded")
    hashes = hash_downloaded_provider_references()
    hash_path = os.path.join(ARTIFACT_DIR, "provider_reference_hashes.csv")
    if hashes:
        for row in hashes:
            row.update(stamp)
        with open(hash_path, "w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(hashes[0].keys()))
            writer.writeheader()
            writer.writerows(hashes)

    by_payer = collections.defaultdict(lambda: {"raw": [], "lab": [], "rel": []})
    for row in hashes:
        if row["status"] == "ok":
            by_payer[row["payer_dir"]]["raw"].append(row["raw_provider_reference_hash"])
            by_payer[row["payer_dir"]]["lab"].append(row["labeled_relationship_hash"])
            by_payer[row["payer_dir"]]["rel"].append(row["relationship_hash"])

    print("\n" + "=" * 96)
    print("PAYER FILE DUPLICATION AUDIT  (metadata only, nothing downloaded)")
    print("=" * 96)
    print(f"{'payer':<24}{'idx(all mo)':>12}{'cmpl month':>11}{'in-net':>8}"
          f"{'uniq url':>10}{'uniq stem':>10}{'stem dup':>9}{'idx/mo':>8}")
    for row in audit:
        print(f"{row['payer_group'][:24]:<24}"
              f"{row['files_indexed_all_months']:>12,}"
              f"{row['files_comparison_month']:>11,}"
              f"{row['in_network_files_comparison_month']:>8,}"
              f"{row['unique_download_urls']:>10,}"
              f"{row['unique_file_stems']:>10,}"
              f"{row['stem_duplication_ratio']:>9}"
              f"{row['index_vs_month_ratio']:>8}")

    if by_payer:
        print("-" * 96)
        print("PROVIDER-REFERENCE DUPLICATION among files already downloaded")
        print(f"{'payer dir':<36}{'files':>7}{'raw':>7}{'labeled':>9}{'relation':>10}{'dup':>7}")
        for payer_dir, values in sorted(by_payer.items()):
            n = len(values["raw"])
            raw_u, lab_u, rel_u = (len(set(values[k])) for k in ("raw", "lab", "rel"))
            print(f"{payer_dir[:36]:<36}{n:>7}{raw_u:>7}{lab_u:>9}{rel_u:>10}"
                  f"{round(n/max(rel_u,1),2):>7}")

    print("=" * 96)
    print(f"audit:  {audit_path}")
    print(f"hashes: {hash_path}")


if __name__ == "__main__":
    sys.exit(main())
