#!/usr/bin/env python3
"""Fetch NPPES candidates for the AMCB midwives from the NPI Registry API.

Follows the client shape of isochrones-A/R/targeted_npi_recovery_r4_nppes.py
(NPI-1 only, tolerant of transient failures) and the 10 req/sec ceiling noted in
memoise_api_setup.R.

Queries by SURNAME rather than by taxonomy, for two reasons the March 2024 bulk
extract got wrong:
  * a CNM may be enumerated under a non-midwifery taxonomy (e.g. WHNP), so
    taxonomy must be a scoring signal, not a filter
  * surname queries return every candidate at once, including their
    ``other_names`` (former/maiden names), which matter a lot in this population

Surnames whose result set is truncated at the API limit are refined by first
name. Responses are cached to nppes_api_cache.jsonl so re-runs are resumable.

Output: nppes_candidates.csv (one row per NPI per name variant)
"""
import csv, json, os, sys, threading, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

API = "https://npiregistry.cms.hhs.gov/api/"
LIMIT = 200
WORKERS = 10
DELAY = 0.1                       # 10 req/sec, memoise_api_setup.R guidance
CACHE = "nppes_api_cache.jsonl"
OUT = "nppes_candidates.csv"

_throttle = threading.Lock()
_last_call = [0.0]


def nppes_query(last, first=None):
    params = {"version": "2.1", "limit": str(LIMIT), "enumeration_type": "NPI-1",
              "last_name": last.upper().strip()}
    if first:
        params["first_name"] = first.upper().strip()
    url = API + "?" + urllib.parse.urlencode(params)
    for attempt in range(4):
        with _throttle:                       # global pacing across workers
            wait = DELAY - (time.monotonic() - _last_call[0])
            if wait > 0:
                time.sleep(wait)
            _last_call[0] = time.monotonic()
        try:
            with urllib.request.urlopen(url, timeout=30) as resp:
                return json.loads(resp.read())
        except Exception as exc:
            if attempt == 3:
                print(f"  failed {last} {first or ''}: {exc}", file=sys.stderr)
                return None
            time.sleep(2 * (attempt + 1))


def load_cache():
    done = {}
    if os.path.exists(CACHE):
        with open(CACHE) as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue          # truncated final line from an interrupted run
                done[rec["query"]] = rec["results"]
    return done


def main():
    with open("midwives.csv") as fh:
        amcb = list(csv.DictReader(fh))
    surnames = sorted({r["last_name"].strip().upper() for r in amcb if r["last_name"].strip()})
    print(f"{len(amcb):,} AMCB records / {len(surnames):,} distinct surnames", file=sys.stderr)

    cache = load_cache()
    cache_lock = threading.Lock()
    log = open(CACHE, "a")

    def fetch(query):
        last, first = query
        key = f"{last}|{first or ''}"
        if key in cache:
            return cache[key], False
        data = nppes_query(last, first)
        results = (data or {}).get("results", []) or []
        with cache_lock:
            log.write(json.dumps({"query": key, "results": results}) + "\n")
            log.flush()
            cache[key] = results
        return results, True

    def run(queries, label):
        truncated, done = [], 0
        with ThreadPoolExecutor(WORKERS) as pool:
            for (query, (results, fetched)) in zip(queries, pool.map(fetch, queries)):
                done += 1
                if len(results) >= LIMIT:
                    truncated.append(query[0])
                if done % 500 == 0:
                    print(f"  {label}: {done:,}/{len(queries):,}", file=sys.stderr)
        return truncated

    if os.environ.get("NPI_BUILD_ONLY") == "1":
        # Rebuild the candidate CSV from whatever is already cached, without
        # issuing any requests -- useful for testing the matcher mid-fetch.
        print(f"build-only: {len(cache):,} cached queries", file=sys.stderr)
        truncated = []
    else:
        truncated = run([(s, None) for s in surnames], "surnames")
    print(f"{len(truncated):,} surnames hit the {LIMIT}-row API limit; "
          f"refining by first name", file=sys.stderr)

    if truncated and os.environ.get("NPI_BUILD_ONLY") != "1":
        big = set(truncated)
        refine = sorted({(r["last_name"].strip().upper(),
                          r["first_name"].strip().upper().split()[0])
                         for r in amcb
                         if r["last_name"].strip().upper() in big and r["first_name"].strip()})
        still = run(refine, "refine")
        if still:
            print(f"  note: {len(still)} first-name queries still truncated", file=sys.stderr)

    log.close()

    seen, rows = set(), []
    for results in cache.values():
        for r in results:
            npi = r.get("number")
            basic = r.get("basic", {}) or {}
            addresses = r.get("addresses") or []
            addr = next((a for a in addresses
                         if a.get("address_purpose") == "LOCATION"), None)
            if addr is None:
                # No practice location on file. A MAILING address is often a PO
                # box or billing office, so keep it but record what it is --
                # geocoding a billing office as a practice site is a silent
                # error that no downstream step can detect.
                addr = addresses[0] if addresses else {}
            taxa = r.get("taxonomies") or []
            primary = next((t for t in taxa if t.get("primary")), taxa[0] if taxa else {})
            # One row per name variant: legal name plus every former/other name.
            variants = [(basic.get("first_name"), basic.get("last_name"),
                         basic.get("middle_name"), "legal")]
            for other in (r.get("other_names") or []):
                variants.append((other.get("first_name"), other.get("last_name"),
                                 other.get("middle_name"), other.get("type") or "other"))
            for first, last, middle, kind in variants:
                if not last:
                    continue
                key = (npi, (first or "").upper(), (last or "").upper(), kind)
                if key in seen:
                    continue
                seen.add(key)
                rows.append({
                    "npi": npi,
                    "first_name": (first or "").upper().strip(),
                    "last_name": (last or "").upper().strip(),
                    "middle_name": (middle or "").upper().strip(),
                    "name_variant": kind,
                    "credential": (basic.get("credential") or "").upper().strip(),
                    "sex": basic.get("sex") or "",
                    "enumeration_date": basic.get("enumeration_date") or "",
                    "taxonomy": primary.get("code") or "",
                    "taxonomy_desc": primary.get("desc") or "",
                    "all_taxonomies": "|".join(t.get("code", "") for t in taxa),
                    "practice_address": (addr.get("address_1") or "").upper().strip(),
                    "practice_city": (addr.get("city") or "").upper().strip(),
                    "practice_state": (addr.get("state") or "").upper().strip(),
                    "practice_zip": (addr.get("postal_code") or "")[:5],
                    "address_purpose": addr.get("address_purpose") or "",
                })

    fields = ["npi", "first_name", "last_name", "middle_name", "name_variant",
              "credential", "sex", "enumeration_date", "taxonomy", "taxonomy_desc",
              "all_taxonomies", "practice_address", "practice_city",
              "practice_state", "practice_zip", "address_purpose"]
    with open(OUT, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows):,} candidate name-rows "
          f"({len({r['npi'] for r in rows}):,} NPIs) to {OUT}", file=sys.stderr)


main()
