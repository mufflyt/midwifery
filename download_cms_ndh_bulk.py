#!/usr/bin/env python3
# =============================================================================
# Download + verify the CMS National Provider Directory (NDH) bulk release
# =============================================================================
#
# WHY. https://directory.cms.gov/downloads publishes the entire NDH as 8
# zstd-compressed NDJSON files (see docs/TECHNICAL_APPENDIX_CMS_NDH.md s7).
# Decompressed, the two relevant files alone are ~28 GB -- this project's
# internal disk had only 20 GB free when this was written, which is exactly
# the shape of the incident accessmrf_config.py documents (105M duplicated
# rows filling a disk). This script therefore NEVER decompresses anything:
# it downloads the .zst files only, verifies them, and leaves decompression
# to clean_cms_ndh_bulk.py, which streams `zstd -dc` straight into a parser
# and never writes the expanded NDJSON to disk at all.
#
# NO DEFAULT ROOT, same discipline as accessmrf_config.py and for the same
# reason: a hardcoded /Volumes/<name> path goes stale the moment macOS
# remounts the drive under a new suffix, and silently writing 2+ GB to
# whatever now occupies that path is worse than refusing to start.
#
# VERIFICATION. The manifest publishes byte sizes but -- despite the
# downloads page's own claim -- no checksums (confirmed by inspection, see
# the appendix s7 caveat). Byte-size match is therefore necessary but not
# sufficient; `zstd -t` (frame integrity test) is the strongest check
# actually available and is run on every file, including ones already on
# disk from a prior run.
#
# ATOMICITY. Downloads land at "<file>.part" and are renamed into place only
# after both the size check and the zstd integrity test pass -- a run killed
# mid-download leaves a ".part" file, never a corrupt-but-correctly-named one
# that a future run's size check could not distinguish from a file corrupted
# some other way.
#
# Inputs : none (the manifest is itself fetched fresh each run)
# Outputs: <root>/manifest.json, <root>/NN-Resource.ndjson.zst (x8),
#          <root>/manifest.json.provenance.json
#
# Usage  : CMS_NDH_BULK_ROOT=/Volumes/<volume>/midwifery/cms_ndh_bulk \
#          python3 download_cms_ndh_bulk.py
# =============================================================================
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools"))
from provenance import sha256_file, utc_now, write_provenance  # noqa: E402

ROOT_ENV_VAR = "CMS_NDH_BULK_ROOT"
MANIFEST_URL = "https://directory.cms.gov/downloads/manifest.json"
DOWNLOADS_BASE = "https://directory.cms.gov/downloads"
MIN_FREE_BYTES = 5 * 1024 ** 3  # refuse to start below 5 GiB free, same floor as accessmrf


class BulkRootUnavailable(RuntimeError):
    pass


def resolve_root():
    root = os.environ.get(ROOT_ENV_VAR, "").strip()
    if not root:
        raise BulkRootUnavailable(
            f"{ROOT_ENV_VAR} is not set. Point it at a writable directory, e.g.\n"
            f'    export {ROOT_ENV_VAR}="/Volumes/<volume>/midwifery/cms_ndh_bulk"\n'
            f"There is no default: a hardcoded /Volumes path goes stale when "
            f"macOS remounts a drive under a different suffix.")
    os.makedirs(root, exist_ok=True)
    probe = os.path.join(root, ".write_probe")
    try:
        with open(probe, "w") as f:
            f.write("ok")
        os.remove(probe)
    except OSError as e:
        raise BulkRootUnavailable(f"{root!r} is not writable: {e}")
    return root


def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def fetch_manifest(root):
    path = os.path.join(root, "manifest.json")
    urllib.request.urlretrieve(MANIFEST_URL, path)
    with open(path, encoding="utf-8") as f:
        return json.load(f), path


def zstd_integrity_ok(path):
    """`zstd -t` decompresses and checks the frame's own integrity -- the
    strongest verification available given the manifest carries no checksum.
    """
    result = subprocess.run(["zstd", "-t", path], capture_output=True)
    return result.returncode == 0


def download_one(url, final_path, expected_bytes, root):
    free = shutil.disk_usage(root).free
    if free < MIN_FREE_BYTES:
        raise BulkRootUnavailable(
            f"Only {free / 1024**3:.1f} GiB free on {root!r}; "
            f"{MIN_FREE_BYTES / 1024**3:.1f} GiB required. Aborting before writing.")

    part_path = final_path + ".part"
    log(f"  GET {url} -> {part_path}")
    urllib.request.urlretrieve(url, part_path)

    got = os.path.getsize(part_path)
    if got != expected_bytes:
        os.remove(part_path)
        raise BulkRootUnavailable(
            f"{os.path.basename(final_path)}: downloaded {got} bytes, "
            f"manifest says {expected_bytes}. Deleted the partial file.")

    if not zstd_integrity_ok(part_path):
        os.remove(part_path)
        raise BulkRootUnavailable(
            f"{os.path.basename(final_path)}: failed zstd frame integrity check. "
            f"Deleted the corrupt file.")

    os.replace(part_path, final_path)  # atomic rename into place


def main():
    root = resolve_root()
    manifest, manifest_path = fetch_manifest(root)
    log(f"manifest generated_at={manifest.get('generated_at')} "
        f"files={len(manifest['files'])} "
        f"total_compressed={manifest['totals']['compressed_bytes']:,} bytes")

    results = {}
    for name in sorted(manifest["files"]):
        zst_name = name + ".zst"
        final_path = os.path.join(root, zst_name)
        expected = manifest["files"][name]["compressed_bytes"]

        if os.path.exists(final_path) and os.path.getsize(final_path) == expected \
                and zstd_integrity_ok(final_path):
            log(f"SKIP {zst_name} (already present, size+integrity verified)")
            results[zst_name] = "already_verified"
            continue

        try:
            download_one(f"{DOWNLOADS_BASE}/{zst_name}", final_path, expected, root)
            log(f"OK   {zst_name} ({expected:,} bytes, size+integrity verified)")
            results[zst_name] = "downloaded_verified"
        except BulkRootUnavailable as e:
            log(f"FAIL {zst_name}: {e}")
            results[zst_name] = f"failed: {e}"

    failed = {k: v for k, v in results.items() if v.startswith("failed")}
    log(f"--- done: {len(results) - len(failed)}/{len(results)} verified, "
        f"{len(failed)} failed ---")

    write_provenance(
        manifest_path,
        source_url=MANIFEST_URL,
        accessed_utc=utc_now(),
        source_dataset="CMS National Directory of Healthcare Providers and Services (NDH), bulk NDJSON release",
        release_generated_at=manifest.get("generated_at"),
        files=results,
        file_sha256={
            name + ".zst": sha256_file(os.path.join(root, name + ".zst"))
            for name in manifest["files"]
            if os.path.exists(os.path.join(root, name + ".zst"))
        },
    )
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
