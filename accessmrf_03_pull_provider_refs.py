#!/usr/bin/env python3
"""
AccessMRF Colorado pilot, step 3: pull provider/TIN structures, payer by payer.

Extracts ONLY the provider-group structures. Negotiated-rate payloads are
never parsed: they are the overwhelming majority of every in-network file, and
nothing in this pilot needs a price. An in-network file with a top-level
`provider_references` block can therefore be reduced to a few thousand rows
without touching the rate body.

Two MRF shapes carry the same information and must both be handled:

  provider_references   a top-level block of
                        {provider_group_id, network_name, provider_groups:[...]}
                        Carries network_name AND tin.business_name.

  inline                provider_groups nested under each negotiated_rates
                        entry, with NO network_name and NO business_name.
                        Reaching these DOES require walking in_network, so the
                        schema_type is recorded per row and completeness flags
                        follow from it downstream.

State targeting is by file stem. Payers encode the state in the filename
(KFHP_CO-COMMERCIAL, KPIC_CO-COMMERCIAL); there is no state field anywhere
inside an MRF, so the filename is the only pre-download signal available.
Every selection is written to the manifest so it can be audited.

Usage:
    accessmrf_03_pull_provider_refs.py --slug <accessmrf-slug> \
        --payer-group "KAISER FOUNDATION GRP" --stem-pattern '(^|[_-])CO[-_]' \
        [--max-bytes 2000000000] [--limit 20]
"""

import argparse
import csv
import gzip
import hashlib
import json
import os
import re
import ssl
import sys
import urllib.request

API = "https://www.accessmrf.com/api"
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")


def _ssl_context():
    """This Homebrew Python has no usable CA bundle.

    `ssl.get_default_verify_paths()` points at /usr/local/etc/openssl@3/cert.pem,
    which does not exist, so every HTTPS request dies with
    CERTIFICATE_VERIFY_FAILED. certifi ships the Mozilla roots, so it is used
    when present. Verification is never disabled: these downloads decide what
    goes into the dataset, and an unverified transport would let anything
    answer for a payer's endpoint.
    """
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except ImportError:
        return ssl.create_default_context()


SSL_CONTEXT = _ssl_context()

RAW_DIR = os.path.join("data", "raw", "accessmrf")
ARTIFACT_DIR = os.path.join("artifacts", "accessmrf")
OBS_PATH = os.path.join(ARTIFACT_DIR, "colorado_provider_observations.csv")
MANIFEST_PATH = os.path.join(ARTIFACT_DIR, "colorado_file_manifest.csv")

OBS_COLUMNS = ["npi", "tin", "tin_type", "business_name", "payer_group", "payer_source",
               "network_name", "source_file_id", "source_file_stem",
               "source_month", "source_url", "schema_type"]
MANIFEST_COLUMNS = ["payer_group", "payer_source", "file_id", "file_stem",
                    "file_date", "schema", "compressed_bytes", "source_url",
                    "local_path", "sha256", "status", "observations"]


def get_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=120, context=SSL_CONTEXT) as response:
        return json.load(response)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def norm_npi(value):
    digits = re.sub(r"\D", "", str(value or ""))
    # A 10-digit NPI is the only valid form. UHC emits a literal "0" as a
    # placeholder in some provider groups; it is dropped, not zero-padded.
    return digits if len(digits) == 10 else ""


def norm_tin(value, tin_type):
    """Normalise a billing identifier WITHOUT mixing identifier spaces.

    The TiC schema allows `tin.type` to be "ein" OR "npi", and payers use both
    heavily: 83% of Kaiser's Colorado provider_groups are type "npi", where the
    value is the provider's own NPI used as a self-billing identifier, not an
    employer EIN. Only the `ein` rows describe a billing ORGANISATION; every
    `npi` row is a solo entity by construction and carries no business_name.

    Collapsing both into one `tin` column makes "distinct TINs" meaningless as
    an organisation count and fills the size distribution with artefactual
    1-NPI entries. The type therefore travels with the value, and downstream
    organisation-structure work must filter to type = "ein".
    """
    digits = re.sub(r"\D", "", str(value or ""))
    if not digits:
        return ""
    # EINs are 9 digits; NPIs are 10. Pad only the EIN space.
    return digits.zfill(9) if tin_type == "ein" else digits


def download(url, destination):
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=1800, context=SSL_CONTEXT) as response, \
            open(destination, "wb") as handle:
        while True:
            chunk = response.read(1 << 20)
            if not chunk:
                break
            handle.write(chunk)
    return destination


TRAILING_COMMA = re.compile(rb",(\s*[\]}])")


def open_payload(path):
    """Return a binary stream over the MRF payload, sniffing magic bytes.

    Payers serve whatever they like regardless of what the URL says. Kaiser
    publishes ZIP archives from URLs ending `.json`; others send gzip, others
    plain JSON. Trusting the extension produced
    "Expecting value: line 1 column 1" on three files that had downloaded
    perfectly well.
    """
    with open(path, "rb") as probe:
        magic = probe.read(4)

    if magic[:4] == b"PK\x03\x04":
        import zipfile
        archive = zipfile.ZipFile(path)
        names = [n for n in archive.namelist() if not n.endswith("/")]
        name = max(names, key=lambda n: archive.getinfo(n).file_size)
        return archive.open(name)

    if magic[:2] == b"\x1f\x8b":
        return gzip.open(path, "rb")

    return open(path, "rb")


def stream_provider_references(path, chunk_size=1 << 22):
    """Pull ONLY the top-level `provider_references` array out of an MRF.

    Two problems make `json.load` unusable on real payer files, and this solves
    both by never reading past the block we need:

      SIZE. Kaiser's KFHP Colorado file is 2.7 GB uncompressed and is almost
      entirely `in_network` rate rows. The provider block sits in the first
      few MB. Parsing the whole document to reach it would cost gigabytes of
      RAM for data this pilot explicitly does not want.

      MALFORMED JSON. Kaiser emits trailing commas before array and object
      close -- `1992827869,  ],` -- which is invalid JSON and which strict
      parsers reject outright. The defect is in the published file, not in our
      download; it is repaired on the extracted slice only, so the repair can
      never silently alter a rate payload we did not inspect.

    Returns the decoded list, or None when the file has no such block (the
    inline-provider_groups shape, which the caller handles separately).
    """
    needle = b'"provider_references"'
    stream = open_payload(path)
    try:
        buffer = b""
        start = -1
        while start < 0:
            chunk = stream.read(chunk_size)
            if not chunk:
                return None
            buffer += chunk
            start = buffer.find(needle)
            if start < 0:
                # Keep a tail so the key is not split across a chunk boundary.
                buffer = buffer[-len(needle):]

        bracket = buffer.find(b"[", start)
        while bracket < 0:
            chunk = stream.read(chunk_size)
            if not chunk:
                return None
            buffer += chunk
            bracket = buffer.find(b"[", start)

        depth, index, in_string, escaped = 0, bracket, False, False
        while True:
            while index < len(buffer):
                byte = buffer[index]
                if in_string:
                    if escaped:
                        escaped = False
                    elif byte == 0x5C:      # backslash
                        escaped = True
                    elif byte == 0x22:      # quote
                        in_string = False
                elif byte == 0x22:
                    in_string = True
                elif byte == 0x5B:          # [
                    depth += 1
                elif byte == 0x5D:          # ]
                    depth -= 1
                    if depth == 0:
                        slice_ = buffer[bracket:index + 1]
                        return json.loads(TRAILING_COMMA.sub(rb"\1", slice_))
                index += 1
            chunk = stream.read(chunk_size)
            if not chunk:
                return None
            buffer += chunk
    finally:
        stream.close()


def load_mrf(path):
    """Full parse, with the trailing-comma repair. Small files only."""
    with open_payload(path) as stream:
        raw = stream.read()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return json.loads(TRAILING_COMMA.sub(rb"\1", raw))


def extract(doc, meta):
    """Yield one row per (npi, tin) observation, tagged with its schema shape."""
    rows = []

    def emit(group, network_name, schema_type):
        tin = group.get("tin") or {}
        tin_type = (tin.get("type") or "").lower()
        tin_value = norm_tin(tin.get("value"), tin_type)
        business_name = tin.get("business_name") or ""
        for raw_npi in (group.get("npi") or []):
            npi = norm_npi(raw_npi)
            if not npi or not tin_value:
                continue
            rows.append({**meta, "npi": npi, "tin": tin_value,
                         "tin_type": tin_type,
                         "business_name": business_name,
                         "network_name": network_name,
                         "schema_type": schema_type})

    for reference in (doc.get("provider_references") or []):
        name = reference.get("network_name")
        name = "|".join(name) if isinstance(name, list) else (name or "")
        for group in (reference.get("provider_groups") or []):
            emit(group, name, "provider_references")

    if not doc.get("provider_references"):
        for item in (doc.get("in_network") or []):
            for rate in (item.get("negotiated_rates") or []):
                for group in (rate.get("provider_groups") or []):
                    emit(group, "", "inline_provider_groups")

    for item in (doc.get("out_of_network") or []):
        for allowed in (item.get("allowed_amounts") or []):
            tin = allowed.get("tin") or {}
            tin_type = (tin.get("type") or "").lower()
            tin_value = norm_tin(tin.get("value"), tin_type)
            for payment in (allowed.get("payments") or []):
                for provider in (payment.get("providers") or []):
                    for raw_npi in (provider.get("npi") or []):
                        npi = norm_npi(raw_npi)
                        if npi and tin_value:
                            rows.append({**meta, "npi": npi, "tin": tin_value,
                                         "tin_type": tin_type,
                                         "business_name": "", "network_name": "",
                                         "schema_type": "allowed_amounts"})
    return rows


def append_rows(path, columns, rows):
    """Append rows, writing a header only when the file has no usable one.

    `os.path.exists` alone is not enough: truncating the file with `: >` leaves
    a zero-byte file that exists, which silently produced a headerless CSV
    earlier in this pilot.
    """
    needs_header = (not os.path.exists(path)) or os.path.getsize(path) == 0
    with open(path, "a", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        if needs_header:
            writer.writeheader()
        for row in rows:
            writer.writerow({c: row.get(c, "") for c in columns})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--slug", required=True)
    parser.add_argument("--payer-group", required=True)
    parser.add_argument("--stem-pattern", required=True,
                        help="regex selecting state-relevant file stems")
    parser.add_argument("--max-bytes", type=int, default=2_000_000_000,
                        help="skip any single file larger than this")
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--max-full-parse-bytes", type=int, default=300_000_000,
                        help="inline-shape files above this are skipped, not RAM-parsed")
    args = parser.parse_args()

    os.makedirs(ARTIFACT_DIR, exist_ok=True)
    payer_dir = os.path.join(RAW_DIR, args.slug[:60])
    os.makedirs(payer_dir, exist_ok=True)

    source = get_json(f"{API}/sources/{args.slug}")
    display = source.get("displayName", args.slug)
    pattern = re.compile(args.stem_pattern, re.I)

    selected = [f for f in source.get("files", [])
                if pattern.search(f.get("fileStem", ""))]
    selected.sort(key=lambda f: f.get("totalCompressedSize") or 0)

    print(f"[{display}] {len(source.get('files', []))} files indexed, "
          f"{len(selected)} match {args.stem_pattern!r}")

    manifest, total_observations = [], 0
    for entry in selected[:args.limit]:
        size = entry.get("totalCompressedSize") or 0
        record = {"payer_group": args.payer_group, "payer_source": display,
                  "file_id": entry["fileId"], "file_stem": entry["fileStem"],
                  "file_date": entry.get("fileDate", ""),
                  "schema": entry.get("fileSchema", ""),
                  "compressed_bytes": size, "source_url": "", "local_path": "",
                  "sha256": "", "status": "", "observations": 0}

        if size > args.max_bytes:
            record["status"] = f"skipped_too_large({size})"
            append_rows(MANIFEST_PATH, MANIFEST_COLUMNS, [record])
            manifest.append(record)
            print(f"   SKIP {entry['fileStem'][:64]} ({size/1e6:.0f} MB)")
            continue

        try:
            detail = get_json(f"{API}/files/{entry['fileId']}")
            parts = [p for p in detail.get("fileParts", []) if p.get("isAvailable")]
            if not parts:
                record["status"] = "no_available_parts"
                append_rows(MANIFEST_PATH, MANIFEST_COLUMNS, [record])
                manifest.append(record)
                continue

            for index, part in enumerate(parts):
                url = part["fullPath"]
                name = f"{entry['fileStem'][:80]}__{index}"
                name += ".json.gz" if ".gz" in url.split("?")[0] else ".json"
                destination = os.path.join(payer_dir, name)

                if not (os.path.exists(destination) and os.path.getsize(destination) > 1000):
                    print(f"   GET  {entry['fileStem'][:64]} part {index+1}/{len(parts)}")
                    download(url, destination)

                meta = {"payer_group": args.payer_group, "payer_source": display,
                        "source_file_id": entry["fileId"],
                        "source_file_stem": entry["fileStem"],
                        "source_month": entry.get("fileDate", ""),
                        "source_url": url.split("?")[0]}

                # Try the cheap path first: lift the provider_references block
                # without reading the rate body. Only fall back to a full parse
                # when the file uses the inline shape, and only when it is small
                # enough that reading all of it is defensible.
                references = stream_provider_references(destination)
                if references is not None:
                    rows = extract({"provider_references": references}, meta)
                elif os.path.getsize(destination) <= args.max_full_parse_bytes:
                    rows = extract(load_mrf(destination), meta)
                else:
                    record["status"] = "inline_shape_too_large_for_full_parse"
                    append_rows(MANIFEST_PATH, MANIFEST_COLUMNS, [record])
                    manifest.append(record)
                    print(f"        -> inline shape, {os.path.getsize(destination)/1e6:.0f} MB, skipped")
                    continue

                # Written per file, not accumulated. Holding every file's rows
                # until the end cost ~650 MB of Anthem parsing to an OOM kill
                # and lost all of it, because nothing had been flushed yet.
                append_rows(OBS_PATH, OBS_COLUMNS, rows)
                total_observations += len(rows)
                del rows

                record.update({"source_url": url.split("?")[0],
                               "local_path": destination,
                               "sha256": sha256_file(destination),
                               "status": "parsed",
                               "observations": record["observations"] + len(rows)})
                print(f"        -> {len(rows):,} provider observations")

        except Exception as exc:                      # noqa: BLE001
            record["status"] = f"error: {type(exc).__name__}: {exc}"[:200]
            print(f"   ERR  {entry['fileStem'][:52]}: {exc}")

        # Flushed per file too, so a kill mid-run leaves an accurate record of
        # exactly which files were already processed.
        append_rows(MANIFEST_PATH, MANIFEST_COLUMNS, [record])
        manifest.append(record)

    print(f"\n[{display}] {total_observations:,} observations appended to {OBS_PATH}")
    print(f"[{display}] manifest appended to {MANIFEST_PATH}")


if __name__ == "__main__":
    sys.exit(main())
