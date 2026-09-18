#!/usr/bin/env python3
"""Where AccessMRF data lives, and the limits that keep it from eating the disk.

ONE configuration point. The external volume path appears here and nowhere
else, so relocating the archive is a single edit or one environment variable
rather than a grep across the pipeline.

    export MIDWIFERY_MRF_ROOT="/Volumes/<your volume>/midwifery/accessmrf"

THERE IS NO DEFAULT, BY DESIGN. An unset variable is an error, not a cue to
guess. macOS appends a suffix when a volume is mounted more than once -- the
drive here is already mounted as "MufflySamsung 1", not "MufflySamsung" -- so a
hardcoded /Volumes/... path silently becomes wrong after a remount and would
write to a stale mount point or to whatever now occupies that name. The root is
therefore always stated explicitly by the caller.

FAIL CLOSED. If the variable is unset, or the root is missing or unwritable,
`mrf_root()` raises. It does NOT search for another volume and does NOT fall
back to the internal disk: that is exactly how 59 GB of duplicated observations
ended up on a volume already 99% full, and a fallback would reproduce it.

WHY THE GUARDS EXIST

An earlier version wrote one row per (npi, tin) OCCURRENCE with the full
source URL, file stem and business name repeated on every row. Anthem's
Colorado files produced 105,630,684 rows -- 59 GB -- from only 58,921 distinct
NPIs and 8,944 distinct billing identifiers, roughly a 200x duplication factor.
It filled the disk and killed the run.

The grain fix removes the cause. These guards bound the damage if some future
payer surprises us again: a run aborts before writing rather than after the
machine is unusable.
"""

import os
import shutil

ROOT_ENV_VAR = "MIDWIFERY_MRF_ROOT"

# --- resource guards ---------------------------------------------------------
# Deduplicated, Anthem's Colorado files should yield on the order of 5e5
# relationships. A file claiming 50x that is a bug, not a payer with a big
# network, and the run stops instead of filling a volume.
MAX_ROWS_PER_FILE = 25_000_000
MAX_TEMP_BYTES = 20 * 1024 ** 3        # 20 GiB of raw payload per run
MIN_FREE_BYTES = 5 * 1024 ** 3         # refuse to start below 5 GiB free


class MrfRootUnavailable(RuntimeError):
    """The configured archive root cannot be used. Never fall back silently."""


def mrf_root(create=True):
    """Resolve the archive root, or raise.

    Checks that the path exists (or can be made), is a directory, and is
    genuinely writable -- a mounted volume can pass `os.access` and still
    refuse an actual write, which is what the external drive does today.
    """
    root = os.environ.get(ROOT_ENV_VAR, "").strip()

    if not root:
        raise MrfRootUnavailable(
            f"{ROOT_ENV_VAR} is not set. Point it at the archive root, e.g.\n"
            f'    export {ROOT_ENV_VAR}="/Volumes/<volume>/midwifery/accessmrf"\n'
            f"There is no default: a hardcoded /Volumes path goes stale when "
            f"macOS remounts a drive under a different suffix."
        )

    if create:
        try:
            os.makedirs(root, exist_ok=True)
        except OSError as exc:
            raise MrfRootUnavailable(
                f"Cannot create MRF root {root!r}: {exc}. "
                f"Set MIDWIFERY_MRF_ROOT or mount the volume. "
                f"Refusing to fall back to the internal disk."
            ) from exc

    if not os.path.isdir(root):
        raise MrfRootUnavailable(f"MRF root {root!r} is not a directory.")

    probe = os.path.join(root, ".write_probe")
    try:
        with open(probe, "w") as handle:
            handle.write("ok")
        os.remove(probe)
    except OSError as exc:
        raise MrfRootUnavailable(
            f"MRF root {root!r} is not writable: {exc}. "
            f"Refusing to fall back to the internal disk."
        ) from exc

    return root


_VERIFIED_ROOT = None


def verify_root_alive(expected=None):
    """Re-check the archive root MID-RUN, not just at startup.

    macOS remounts a volume under a new suffix when it drops and returns --
    /Volumes/X becomes /Volumes/X 1, then /Volumes/X 2. A long job holding the
    old path keeps running against a directory that no longer refers to the
    disk. One UHC run burned 3h27m of CPU with no open file handles before this
    was noticed, and nothing it computed could be written.

    Called between work units so a vanished root fails in seconds.
    """
    expected = expected or os.environ.get(ROOT_ENV_VAR, "").strip()
    if not expected:
        raise MrfRootUnavailable(f"{ROOT_ENV_VAR} is not set.")
    probe = os.path.join(expected, ".alive_probe")
    try:
        with open(probe, "w") as handle:
            handle.write("ok")
        os.remove(probe)
    except OSError as exc:
        raise MrfRootUnavailable(
            f"MRF root {expected!r} is no longer writable mid-run: {exc}. "
            f"The volume may have remounted under a different suffix -- check "
            f"`mount | grep -i <volume>` and restart with the live path."
        ) from exc
    return expected


def subdir(name, create=True):
    """raw/ parquet/ manifests/ scratch/ under the archive root."""
    path = os.path.join(mrf_root(create=create), name)
    if create:
        os.makedirs(path, exist_ok=True)
    return path


def free_bytes(path):
    return shutil.disk_usage(path).free


def require_free_space(path, minimum=MIN_FREE_BYTES):
    """Abort BEFORE writing if the target volume is too full."""
    free = free_bytes(path)
    if free < minimum:
        raise MrfRootUnavailable(
            f"Only {free / 1024 ** 3:.1f} GiB free on {path!r}; "
            f"{minimum / 1024 ** 3:.1f} GiB required. Aborting before writing."
        )
    return free


def describe():
    """Human-readable status, for logs and for diagnosing a failed run."""
    root = os.environ.get(ROOT_ENV_VAR, "(unset)")
    try:
        resolved = mrf_root()
        return (f"MRF root: {resolved}  "
                f"({free_bytes(resolved) / 1024 ** 3:.1f} GiB free)")
    except MrfRootUnavailable as exc:
        return f"MRF root UNAVAILABLE ({root}): {exc}"


if __name__ == "__main__":
    print(describe())
