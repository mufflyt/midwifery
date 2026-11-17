#!/usr/bin/env python3
"""Prove a saboteur suite has teeth, by breaking the library it guards.

A green suite is not evidence. A suite that stays green while you delete the
guard it is supposed to be testing is a suite that tests nothing, and that has
happened here more than once: during the eight adversarial rounds this harness
was rebuilt from scratch three times because the throwaway version kept
reporting "not caught" for mutants that had actually failed to parse.

Usage
-----
Write a mutation list -- each entry a (file, anchor, replacement, label) where
`anchor` is an exact substring of the file and `replacement` breaks the guard
it belongs to -- and call `run(suite, mutants)`.

    from mutate_saboteurs import run
    run("tests/test_cross_vintage_pairing_saboteurs.R", [
        ("R/lib/state_agreement.R",
         '  if (!"year" %in% names(registry_current)) {',
         "  if (FALSE) {",
         "a registry with no year column is accepted"),
    ])

THREE RULES THIS ENFORCES, each learned by getting it wrong
-----------------------------------------------------------
1. An anchor that is not found is reported, never skipped silently. A stale
   anchor looks exactly like a caught mutant if you only read the exit code,
   and two anchors went stale mid-round because a heredoc mangled them.
2. A mutant must still PARSE. A syntax error makes every suite exit non-zero,
   which reads as "caught" for the wrong reason, and flatters the suite.
3. The suite must have COMPLETED -- its own tally line has to appear. A suite
   that aborts early (a missing fixture, an error before the first assertion)
   also exits non-zero and also reads as "caught".

Surviving mutants are not automatically blind spots: some are genuinely
equivalent, and the only honest way to tell is to check what the mutated code
does rather than assume. Verify each one before dismissing it.
"""
from __future__ import annotations

import pathlib
import re
import shutil
import subprocess
import sys

# A suite's tally line must contain one of these for the run to count.
COMPLETION_MARKERS = ("ALL SABOTEURS HELD", "SABOTEURS FOUND GAPS",
                      "PASS (", "FAIL (", "All checks passed",
                      "ALL PASS", "tests passed")


def _run_suite(suite: str, root: pathlib.Path) -> tuple[int, str]:
    p = subprocess.run(["Rscript", suite], cwd=root, capture_output=True,
                       text=True, errors="replace")
    return p.returncode, p.stdout + p.stderr


def _parses(target: str, root: pathlib.Path) -> bool:
    p = subprocess.run(["Rscript", "-e", f'invisible(parse("{target}"))'],
                       cwd=root, capture_output=True, text=True)
    return p.returncode == 0


def run(suite: str, mutants: list[tuple[str, str, str, str]],
        root: str | pathlib.Path = ".") -> int:
    """Apply each mutant, run `suite`, restore. Returns the survivor count."""
    root = pathlib.Path(root).resolve()
    caught = survived = unusable = 0
    for i, (rel, anchor, replacement, label) in enumerate(mutants, 1):
        path = root / rel
        original = path.read_text()
        if anchor not in original:
            print(f"M{i:02d} ANCHOR NOT FOUND     {label}")
            print(f"      in {rel} -- the mutation never happened, so this says "
                  f"nothing about the suite")
            unusable += 1
            continue
        backup = path.with_suffix(path.suffix + ".mutbak")
        shutil.copy(path, backup)
        path.write_text(original.replace(anchor, replacement, 1))
        try:
            if not _parses(rel, root):
                print(f"M{i:02d} MUTANT DOES NOT PARSE {label}")
                unusable += 1
                continue
            code, out = _run_suite(suite, root)
            if not any(m in out for m in COMPLETION_MARKERS):
                print(f"M{i:02d} SUITE DID NOT COMPLETE {label}")
                print("      " + (out.strip().splitlines() or ["<no output>"])[-1][:120])
                unusable += 1
            elif code != 0:
                n = re.findall(r"(\d+) failure", out)
                print(f"M{i:02d} caught ({n[0] if n else '?'} failures)  {label}")
                caught += 1
            else:
                print(f"M{i:02d} SURVIVED              {label}")
                survived += 1
        finally:
            shutil.move(backup, path)
    print(f"\n{caught} caught, {survived} survived, {unusable} unusable, "
          f"of {len(mutants)}")
    if unusable:
        print("An unusable mutant is a broken TEST OF THE TEST, not a result. "
              "Fix the anchor and re-run before reading anything into the rest.")
    return survived


if __name__ == "__main__":
    print(__doc__)
    sys.exit(0)
