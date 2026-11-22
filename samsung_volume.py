#!/usr/bin/env python3
"""Resolve a path on the Samsung volume, whatever macOS called it today.

The Python half of ``samsung_volume_path()`` / ``samsung_duckdb_path()`` in
R/lib/medicare_duckdb.R. Until this existed, four Python producers spelled the
mount out as a module-level constant, which is two bugs at once:

1. THE RENAME BUG the R resolver was written to kill. macOS mounts a second
   copy of the drive as "MufflySamsung 1". A hardcoded "/Volumes/MufflySamsung"
   keeps answering for whichever one happens to be mounted first, and an audit
   run against the wrong one reports no disagreements -- which reads as a clean
   result, not a broken one.
2. tests/test_duckdb_volume_resolution.R H1/H2 forbid the literal in every
   tracked executable file, in ANY language, with R/lib/medicare_duckdb.R and
   the test itself as the only exemptions. H1/H2 scan *.py for exactly this
   reason, and the nightly failed on them for months.

THE SEMANTICS MATCH THE R SIDE ON PURPOSE, including the part that looks odd:
when nothing is mounted this returns the CANONICAL path rather than None, so a
caller's own existence check fails with a path a human can go and look at
instead of printing "None". Two resolvers answering differently is the
duplicate-definition failure this project has paid for repeatedly.
"""
import glob
import os

# The volume's canonical spelling, named ONCE on the Python side -- the mirror
# of SAMSUNG_VOLUME_CANONICAL in R/lib/medicare_duckdb.R.
SAMSUNG_VOLUME_CANONICAL = "/Volumes/MufflySamsung"
SAMSUNG_VOLUME_GLOB = SAMSUNG_VOLUME_CANONICAL + "*"


def samsung_path(relative, env_var=None):
    """Resolve ``relative`` below the Samsung volume root.

    An explicit ``env_var`` override wins, then a glob over the mounted
    volumes. Raises when more than one volume answers, because guessing is how
    one drive's data silently stands in for another's.
    """
    if env_var:
        override = os.environ.get(env_var, "")
        if override:
            return override

    hits = [p for p in glob.glob(os.path.join(SAMSUNG_VOLUME_GLOB, relative))
            if os.path.exists(p)]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        raise RuntimeError(
            "%s matches %d mounted volumes:\n  %s\n"
            "  Guessing would silently pick one drive's data over another's."
            % (relative, len(hits), "\n  ".join(sorted(hits))))
    return os.path.join(SAMSUNG_VOLUME_CANONICAL, relative)


def demo():
    """Self-check: the three branches, without needing the drive mounted."""
    assert samsung_path("DuckDB/x.duckdb", env_var="SAMSUNG_DEMO_OVERRIDE") \
        == os.path.join(SAMSUNG_VOLUME_CANONICAL, "DuckDB/x.duckdb")

    os.environ["SAMSUNG_DEMO_OVERRIDE"] = "/tmp/elsewhere.duckdb"
    try:
        assert samsung_path("DuckDB/x.duckdb",
                            env_var="SAMSUNG_DEMO_OVERRIDE") == "/tmp/elsewhere.duckdb"
    finally:
        del os.environ["SAMSUNG_DEMO_OVERRIDE"]

    # An unmounted path comes back canonical, never None -- the property the
    # callers' own "missing required input" messages depend on.
    p = samsung_path("DuckDB/definitely_not_mounted_xyz.duckdb")
    assert p.startswith(SAMSUNG_VOLUME_CANONICAL) and not os.path.exists(p)
    print("samsung_volume: ok")


if __name__ == "__main__":
    demo()
