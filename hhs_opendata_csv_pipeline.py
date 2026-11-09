#!/usr/bin/env python3
"""Shared download/verify/extract/load pipeline for opendata.hhs.gov's
single-CSV-zip datasets.

Not a script -- a module. `download_medicaid_provider_enrollment_segments.py`
and `download_medicaid_provider_spending.py` are both thin wrappers around
`run_pipeline()` here, differing only in their dataset constants (blob path,
version date, table name, local/external paths). Extracted 2026-10-23 so the
download/SHA-256-verify/extract/load logic is defined and tested exactly
ONCE: a second hand-copied script is how two "verified" pipelines quietly
drift -- a fix to one (the box-table row-count parsing bug, the blank-end-
date handling) silently failing to reach the other is exactly the kind of
defect this repo's own H4 hygiene gate exists to catch for R; there is no
equivalent CI gate for Python, so the discipline has to be structural here
instead -- one definition, two callers.

Every opendata.hhs.gov dataset observed so far follows the same shape: a
client-rendered Next.js page with no visible download API, backed by a
stable, unauthenticated Azure Blob Storage URL of the form
`https://stopendataprod.blob.core.windows.net/datasets/<slug>/<version-date>/
dataset/<slug>.csv.zip`, with the blob's own `x-ms-meta-sha256` header as the
only integrity oracle -- it proves a download matches what the server is
CURRENTLY serving, not that the server's content is correct. Verification is
always against that live header value, never a hardcoded constant, so a
future republish (new version-date, new checksum) still verifies correctly.

Uses the `duckdb` CLI binary via subprocess, not the Python duckdb package:
this repo's Python CI job installs stdlib + pytest only (see
accessmrf_06_build_relationships.py's write_parquet() for the same pattern).

WHY DOWNLOAD, EXTRACTION AND THE DUCKDB BUILD ALL HAPPEN ON LOCAL DISK, NOT
THE EXTERNAL VOLUME, THEN COPY ONCE. Measured directly on the enrollment-
segments pull: writing the extracted CSV straight to /Volumes/MufflySamsung
gave low, highly variable throughput (bursts of 30-60 MB/s next to multi-
minute stretches under 1 MB/s, with Time Machine's backupd running
concurrently as one plausible contributor). Building locally (fast internal
SSD, no contention) and copying only the FINISHED .duckdb file to the
external volume as one sequential transfer means the slow, contended link
only ever carries bytes once, and DuckDB's own storage format is smaller
than the source CSV, so there is less to move across it besides.
"""
import hashlib
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile
from datetime import datetime, timezone

CHUNK_SIZE = 1 << 20  # 1 MiB


class DownloadVerificationError(Exception):
    """The bytes on disk do not match what the server claimed to be serving."""


class ZipContentError(Exception):
    """The archive does not contain exactly one CSV member."""


def blob_url(blob_base, version_date, zip_filename):
    return f"{blob_base}/{version_date}/dataset/{zip_filename}"


def sha256_file(path, chunk_size=CHUNK_SIZE):
    """Stream a local file through SHA-256 without loading it into memory."""
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(chunk_size), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_blob_metadata(url, opener=urllib.request.urlopen):
    """HEAD the blob for its advertised sha256 (x-ms-meta-sha256) and size.

    Returns {"sha256": str|None, "content_length": int|None}. Both are None
    (not an error) if the server omits them -- the caller decides whether
    that is acceptable; this function only reports what it saw.
    """
    req = urllib.request.Request(url, method="HEAD")
    with opener(req) as resp:
        headers = resp.headers
        sha256 = headers.get("x-ms-meta-sha256")
        length = headers.get("Content-Length")
        return {
            "sha256": sha256.strip().lower() if sha256 else None,
            "content_length": int(length) if length is not None else None,
        }


def download_with_sha256(url, dest_path, expected_sha256=None, expected_size=None,
                          opener=urllib.request.urlopen, chunk_size=CHUNK_SIZE):
    """Stream url to dest_path, hashing and counting bytes as they arrive.

    Verification happens against the ACTUAL bytes written to dest_path (a
    fresh read of the file this function itself wrote), not against the
    in-flight hash alone -- a mutation that reports success without that
    final independent read is exactly what the saboteur tests probe for.
    Raises DownloadVerificationError on any mismatch; dest_path is left on
    disk either way (callers that want "no partial file on failure" should
    remove it themselves) so a failed download can be inspected.
    """
    req = urllib.request.Request(url)
    size = 0
    tmp_path = dest_path + ".part"
    with opener(req) as resp, open(tmp_path, "wb") as out:
        for chunk in iter(lambda: resp.read(chunk_size), b""):
            out.write(chunk)
            size += len(chunk)
    os.replace(tmp_path, dest_path)

    actual_sha256 = sha256_file(dest_path)

    if expected_size is not None and size != expected_size:
        raise DownloadVerificationError(
            f"downloaded {size} bytes, server advertised Content-Length {expected_size}")
    if expected_sha256 is not None and actual_sha256 != expected_sha256:
        raise DownloadVerificationError(
            f"downloaded file sha256 {actual_sha256} does not match "
            f"server-advertised x-ms-meta-sha256 {expected_sha256}")

    return {"sha256": actual_sha256, "size": size}


def zip_member_sizes(zip_path):
    """Compressed/uncompressed size of every CSV member, from the central
    directory only -- no extraction, so this is cheap even on a multi-GB
    archive. Used to check disk headroom before committing to extraction.
    """
    if not zipfile.is_zipfile(zip_path):
        raise ZipContentError(f"{zip_path} is not a valid zip archive "
                               f"(the server may have returned an error page)")
    with zipfile.ZipFile(zip_path) as zf:
        return {info.filename: (info.compress_size, info.file_size)
                for info in zf.infolist() if info.filename.lower().endswith(".csv")}


def extract_single_csv(zip_path, dest_dir):
    """Extract the archive's one CSV member; refuse anything else.

    Zero CSV members (wrong/empty archive) and more than one (ambiguous --
    which one is the dataset?) are both hard errors. This also rejects a
    file that is not actually a zip (e.g. an HTML error page served with a
    .zip extension after an expired/broken blob URL) with a clear message
    instead of letting zipfile.BadZipFile surface as a bare traceback.

    Validation (is_zipfile / namelist) stays on Python's zipfile module --
    cheap, since it only reads the central directory. The actual extraction
    shells out to the `unzip` CLI rather than zipfile.extract(): on an
    11 GB member over a slow external USB drive, zipfile's pure-Python
    decompress loop measured under 1.5 MB/s and falling, against ~50 MB/s
    for `unzip` writing the same bytes to the same drive -- a Python-side
    bottleneck, not a disk one.
    """
    members = zip_member_sizes(zip_path)
    if len(members) != 1:
        raise ZipContentError(
            f"expected exactly one .csv member in {zip_path}, found "
            f"{len(members)}: {list(members)}")
    member = next(iter(members))

    os.makedirs(dest_dir, exist_ok=True)
    result = subprocess.run(["unzip", "-o", zip_path, member, "-d", dest_dir],
                             capture_output=True, text=True)
    out_path = os.path.join(dest_dir, member)
    if result.returncode != 0 or not os.path.exists(out_path):
        raise ZipContentError(
            f"unzip failed extracting {member} from {zip_path} "
            f"(exit {result.returncode}):\n{result.stderr}")
    return out_path


def run_duckdb_sql(db_path, sql):
    """Run one SQL statement (or script) against db_path via the duckdb CLI."""
    result = subprocess.run(["duckdb", db_path, "-c", sql],
                             capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"duckdb CLI failed on {db_path}:\n{result.stderr}")
    return result.stdout


def count_rows(db_path, table_name):
    # -noheader -list: one bare value per line, no box-drawing border -- the
    # default box-table format wraps "1" as "│            1 │", which is not
    # digit-only and would make a naive parse of the default format silently
    # find nothing to match.
    result = subprocess.run(
        ["duckdb", db_path, "-noheader", "-list", "-c",
         f"SELECT COUNT(*) FROM {table_name};"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"duckdb CLI failed on {db_path}:\n{result.stderr}")
    lines = [ln for ln in result.stdout.strip().splitlines() if ln.strip()]
    if not lines or not lines[-1].strip().isdigit():
        raise RuntimeError(f"could not parse row count from duckdb output:\n{result.stdout}")
    return int(lines[-1])


def load_csv_to_duckdb(csv_path, db_path, table_name):
    """(Re)create table_name in db_path from csv_path. Empty is a failure.

    all_varchar=true, deliberately: these datasets' own documentation warns
    that NPI columns can hold the literal "0000000000" and that date columns
    carry sentinel values like 1900-01-01, 1970-01-01 and 9999-12-31 --
    exactly the values a type-inferring reader is most likely to mishandle
    (leading-zero loss on a numeric NPI; a DATE parser rejecting or nulling
    an out-of-range sentinel). Reading everything as text and leaving typed
    parsing to downstream consumers avoids both failure modes silently.
    """
    escaped = csv_path.replace("'", "''")
    run_duckdb_sql(
        db_path,
        f"CREATE OR REPLACE TABLE {table_name} AS "
        f"SELECT * FROM read_csv('{escaped}', all_varchar=true, "
        f"sample_size=-1, header=true);")
    n = count_rows(db_path, table_name)
    if n == 0:
        raise RuntimeError(
            f"{table_name} loaded with zero rows -- treated as a failed load, "
            f"not a successful empty one")
    return n


def record_provenance(db_path, meta):
    """Append one row to _provenance (created on first use)."""
    run_duckdb_sql(
        db_path,
        "CREATE TABLE IF NOT EXISTS _provenance ("
        "  loaded_at TIMESTAMP, table_name VARCHAR, source_url VARCHAR, "
        "  version_date VARCHAR, zip_sha256 VARCHAR, zip_bytes BIGINT, "
        "  row_count BIGINT"
        ");")
    vals = (
        meta["loaded_at"], meta["table_name"], meta["source_url"],
        meta["version_date"], meta["zip_sha256"], meta["zip_bytes"],
        meta["row_count"],
    )
    placeholders = ", ".join(
        "'" + str(v).replace("'", "''") + "'" if not isinstance(v, (int, float)) else str(v)
        for v in vals)
    run_duckdb_sql(db_path, f"INSERT INTO _provenance VALUES ({placeholders});")


def copy_and_verify(local_db_path, final_db_path, table_name, expected_rows):
    """Copy the finished local DuckDB file to its final destination once.

    Verifies by re-opening the COPY and recounting -- the same discipline as
    download_with_sha256's post-write re-read -- rather than trusting that a
    copy which didn't raise necessarily produced byte-identical content.
    """
    os.makedirs(os.path.dirname(final_db_path), exist_ok=True)
    shutil.copy2(local_db_path, final_db_path)
    n_final = count_rows(final_db_path, table_name)
    if n_final != expected_rows:
        raise RuntimeError(
            f"copy verification failed: local build had {expected_rows:,} rows, "
            f"copy at {final_db_path} has {n_final:,}")
    return n_final


def run_pipeline(blob_base, version_date, zip_filename, table_name,
                  work_dir, db_path,
                  force_download=False, force_reload=False, keep_csv=False):
    """Download, verify, extract, load and copy -- the full pipeline for one
    opendata.hhs.gov single-CSV-zip dataset. See module docstring for why
    every step happens where it happens.
    """
    os.makedirs(work_dir, exist_ok=True)
    zip_path = os.path.join(work_dir, zip_filename)
    local_db_path = os.path.join(work_dir, os.path.basename(db_path))
    url = blob_url(blob_base, version_date, zip_filename)

    meta = fetch_blob_metadata(url)
    if meta["sha256"] is None:
        print("WARNING: server did not advertise x-ms-meta-sha256; "
              "downloading without integrity verification", file=sys.stderr)

    need_download = force_download or not os.path.exists(zip_path)
    if not need_download:
        # A cached zip is only trusted after a FRESH hash of what is actually
        # on disk, re-checked against the server's CURRENT header -- not
        # merely because a file with the right name exists.
        on_disk_sha256 = sha256_file(zip_path)
        if meta["sha256"] is not None and on_disk_sha256 != meta["sha256"]:
            print(f"cached zip sha256 {on_disk_sha256} no longer matches "
                  f"server {meta['sha256']}; re-downloading", file=sys.stderr)
            need_download = True
        else:
            print(f"using cached {zip_path} (sha256 verified against server)",
                  file=sys.stderr)

    if need_download:
        print(f"downloading {url}", file=sys.stderr)
        dl = download_with_sha256(url, zip_path, expected_sha256=meta["sha256"],
                                   expected_size=meta["content_length"])
        print(f"downloaded {dl['size']:,} bytes, sha256 {dl['sha256']} verified",
              file=sys.stderr)

    zip_sha256 = sha256_file(zip_path)
    zip_bytes = os.path.getsize(zip_path)

    final_has_rows = False
    if not force_reload and os.path.exists(db_path):
        try:
            final_has_rows = count_rows(db_path, table_name) > 0
        except RuntimeError:
            final_has_rows = False

    if final_has_rows and not force_reload:
        n = count_rows(db_path, table_name)
        print(f"{table_name} already has {n:,} rows in {db_path}; "
              f"pass --force-reload to rebuild from the zip", file=sys.stderr)
    else:
        members = zip_member_sizes(zip_path)
        for name, (csize, usize) in members.items():
            print(f"zip member {name}: {csize:,} compressed -> {usize:,} uncompressed bytes",
                  file=sys.stderr)
        free_bytes = shutil.disk_usage(work_dir).free
        total_uncompressed = sum(u for _, u in members.values())
        if total_uncompressed > free_bytes:
            raise RuntimeError(
                f"{total_uncompressed:,} bytes uncompressed would not fit in "
                f"{free_bytes:,} free bytes at {work_dir} -- aborting before "
                f"extraction rather than filling the disk")

        csv_path = extract_single_csv(zip_path, work_dir)
        print(f"extracted {csv_path}", file=sys.stderr)
        n = load_csv_to_duckdb(csv_path, local_db_path, table_name)
        print(f"loaded {n:,} rows into {table_name} ({local_db_path}, local)",
              file=sys.stderr)
        record_provenance(local_db_path, {
            "loaded_at": datetime.now(timezone.utc).isoformat(),
            "table_name": table_name,
            "source_url": url,
            "version_date": version_date,
            "zip_sha256": zip_sha256,
            "zip_bytes": zip_bytes,
            "row_count": n,
        })
        if not keep_csv:
            os.remove(csv_path)
        print(f"copying {local_db_path} -> {db_path}", file=sys.stderr)
        copy_and_verify(local_db_path, db_path, table_name, n)
        print(f"verified {n:,} rows in {db_path}", file=sys.stderr)

    return {"db_path": db_path, "table_name": table_name, "row_count": n,
            "zip_sha256": zip_sha256, "zip_path": zip_path}
