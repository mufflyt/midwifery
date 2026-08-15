#!/usr/bin/env python3
"""Write a CSV together with its .provenance.json sidecar.

The Python half of R/lib/artifact_provenance.R. Until this existed there was no
Python path to provenance at all, while 13 of the 20 artifacts that broke the A3
contract came from Python producers -- so the failure message told their authors
to call write_with_provenance(), a function that existed only in R.

THE SCHEMA IS DELIBERATELY IDENTICAL TO THE R WRITER:

    {"artifact": "<basename>",
     "written_utc": "<YYYY-MM-DD HH:MM:SS UTC>",
     "inputs": [{"path": "<repo-relative>", "sha256": "<hex>"}]}

Two writers emitting two shapes is the duplicate-definition failure this project
has paid for repeatedly -- safe_divide.R drifted 181 lines from its own SSOT and
a one-line guard passed throughout. If a field is added here it must be added
there in the same change.

WHAT A SIDECAR CAN AND CANNOT SAY. It records the inputs as they were WHEN THE
ARTIFACT WAS WRITTEN, hashed at that moment. It cannot be produced afterwards:
hashing the inputs today tells you what they contain today, not what produced a
file written last week. That is why the twenty artifacts already committed
without sidecars cannot be back-filled, only re-recorded by re-running their
producers -- and why this must be called at write time rather than bolted on.
"""
import csv
import datetime
import hashlib
import json
import os


def sha256_of(path):
    """Hex SHA-256 of a file, streamed so a multi-gigabyte input is safe."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def repo_relative(path, root=None):
    """Path relative to the repository root, so sidecars are portable."""
    root = root or os.getcwd()
    try:
        return os.path.relpath(os.path.abspath(path), os.path.abspath(root))
    except ValueError:
        return path


def write_provenance(path, inputs=(), root=None):
    """Write only the sidecar, for a payload written by other means.

    Silently drops inputs that do not exist, matching the R writer: a recorded
    input must be one that was actually read, and a path that is not there was
    not read.
    """
    present = [p for p in inputs if os.path.exists(p)]
    side = str(path) + ".provenance.json"

    payload = {
        "artifact": os.path.basename(str(path)),
        "written_utc": datetime.datetime.now(
            datetime.timezone.utc
        ).strftime("%Y-%m-%d %H:%M:%S UTC"),
        "inputs": [
            {"path": repo_relative(p, root), "sha256": sha256_of(p)}
            for p in present
        ],
    }

    with open(side, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")

    return side


def write_with_provenance(rows, path, fieldnames=None, inputs=(), root=None):
    """Write rows to CSV and emit the sidecar in the same call.

    One call on purpose. A separate write-then-record pair is one refactor away
    from a payload with no sidecar, which is the state this module exists to
    stop.

    rows may be a list of dicts (fieldnames inferred from the first) or a list
    of sequences (fieldnames required).
    """
    rows = list(rows)

    parent = os.path.dirname(str(path))
    if parent:
        os.makedirs(parent, exist_ok=True)

    with open(path, "w", encoding="utf-8", newline="") as f:
        if rows and isinstance(rows[0], dict):
            names = fieldnames or list(rows[0].keys())
            writer = csv.DictWriter(f, fieldnames=names)
            writer.writeheader()
            writer.writerows(rows)
        else:
            writer = csv.writer(f)
            if fieldnames:
                writer.writerow(fieldnames)
            writer.writerows(rows)

    write_provenance(path, inputs=inputs, root=root)
    return path
