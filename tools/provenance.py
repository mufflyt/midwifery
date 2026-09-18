#!/usr/bin/env python3
"""One provenance vocabulary for the Python harvesters.

WHY THIS EXISTS. ``write_with_provenance()`` lives only in
``R/lib/artifact_provenance.R``, so "write it through write_with_provenance()"
was not advice a Python producer could follow -- and the Python producers are
the live board-of-nursing harvesters, which carry the evidence that replaced
the fabricated licence identifiers
(``docs/PROVENANCE_DEFECT_BON_LICENSE_IDENTIFIERS.md``).

Left to themselves, three of them invented three vocabularies for the same two
facts -- Texas recorded ``source_api``/``retrieved_utc``, Florida and Oregon
recorded ``verification_portal``/``timestamp``, and Washington and Colorado
recorded nothing at all -- so no automated check could read any of them, and
``tests/ci_repo_integrity.R``'s rule (``source_url`` AND ``accessed_utc``)
would have rejected all five. That rule failed a commit for pulling two ACS
files into ``data/`` without a sidecar, while the artifacts that replaced
fabricated licence numbers were exempt from it. See issue #230.

This writes ``source_url`` and ``accessed_utc`` under those exact names, and
carries whatever richer fields a harvester already records (raw payload
archive, cohort SHA-256, retrieval counts, imputation policy) alongside them
rather than in place of them. Additive, not a replacement.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
from typing import Any, Dict, Optional

#: The two keys ``tests/ci_repo_integrity.R`` requires by name.
REQUIRED_KEYS = ("source_url", "accessed_utc")


def utc_now() -> str:
    """Retrieval time as ``2026-09-18T16:52:43Z``, the shape the gate parses."""
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: str) -> str:
    """SHA-256 of a file, read in chunks so a large payload does not load whole."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def write_provenance(
    artifact_path: str,
    source_url: str,
    accessed_utc: Optional[str] = None,
    sidecar_path: Optional[str] = None,
    **extra: Any,
) -> str:
    """Write ``<artifact>.provenance.json`` next to an artifact.

    Args:
        artifact_path: the artifact this describes. Its SHA-256 and byte size
            are measured here rather than passed in, so they cannot drift from
            the bytes actually written.
        source_url: the URL the data came from -- the API endpoint that was
            queried, not the human-facing lookup page. A portal a person would
            visit belongs in ``extra`` as ``verification_portal``.
        accessed_utc: when it was retrieved. Defaults to now, which is correct
            only when this is called in the same run as the fetch. Pass an
            explicit value when backfilling, and pass ``None`` in ``extra`` with
            a ``provenance_status`` rather than inventing one.
        sidecar_path: override the default ``artifact_path + ".provenance.json"``.
        **extra: any further fields to record. Keys given here win over the
            defaults, so a harvester can record its own hash of a raw payload
            instead of the artifact's.

    Returns:
        The path written.
    """
    if not source_url:
        raise ValueError("source_url is required: an artifact with no recorded "
                         "source cannot be re-fetched or dated later")

    record: Dict[str, Any] = {
        "artifact": os.path.basename(artifact_path),
        "source_url": source_url,
        "accessed_utc": accessed_utc if accessed_utc is not None else utc_now(),
    }
    if os.path.exists(artifact_path):
        record["sha256"] = sha256_file(artifact_path)
        record["byte_size"] = os.path.getsize(artifact_path)
    record.update(extra)

    out = sidecar_path or (artifact_path + ".provenance.json")
    with open(out, "w", encoding="utf-8") as f:
        json.dump(record, f, indent=2)
        f.write("\n")
    return out
