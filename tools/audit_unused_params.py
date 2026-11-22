#!/usr/bin/env python3
"""List R/lib parameters whose default no caller ever overrides.

Dead flexibility -- a switch with one position, a weight nobody tunes -- is
worth finding. But this tool's first version produced a WRONG finding and it is
worth saying how, because the same mistake is easy to repeat.

THE BUG: it searched only for `param = value` at call sites. R callers pass
positionally, so `trl_rank_candidates(scored, "identity_only")` does not match
`variant =` anywhere, and the tool reported `variant` as an abstraction with
one implementation. It has two, both scored, ranked, decided and reported
against each other as a scientific comparison. Acting on that finding would
have deleted half of a published result.

So this counts BOTH forms: named, and positional by argument index. It also
separates three outcomes rather than two, because they call for different
things:

  never        no caller passes it, named or positional, anywhere
  tests only   exercised by tests but by no production script
  used         a production caller overrides it

Only `never` is a candidate, and not even all of those: many are deliberate
injection points (`path=`, `data_root=`, `art_dir=`) that exist so a test can
redirect I/O, and several in this repository carry written rationale for why.
Read the rationale before cutting. A parameter with a comment explaining why it
exists is not dead flexibility; it is documented flexibility.

Usage:  python3 tools/audit_unused_params.py [lib_dir]
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import sys

SIG = re.compile(r'^([a-zA-Z_.][A-Za-z0-9_.]*)\s*<-\s*function\s*\((.*?)\)\s*\{',
                 re.S | re.M)


def split_args(text: str) -> list[str]:
    """Split on top-level commas only -- defaults contain commas of their own."""
    depth, cur, out = 0, "", []
    for ch in text:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def call_args(text: str, start: int) -> list[str] | None:
    """The argument list of a call whose open paren is at `start`."""
    depth = 0
    for i in range(start, min(len(text), start + 4000)):
        if text[i] in "([{":
            depth += 1
        elif text[i] in ")]}":
            depth -= 1
            if depth == 0:
                return split_args(text[start + 1:i])
    return None


def main(lib_dir: str = "R/lib") -> int:
    root = pathlib.Path(".").resolve()
    tracked = subprocess.run(["git", "ls-files"], cwd=root, capture_output=True,
                             text=True).stdout.split()
    code = [f for f in tracked if f.endswith((".R", ".qmd"))]
    text = {}
    for f in code:
        try:
            text[f] = (root / f).read_text(errors="replace")
        except OSError:
            pass

    rows = []
    for f in [c for c in code if c.startswith(lib_dir)]:
        for m in SIG.finditer(text.get(f, "")):
            fn, params = m.group(1), m.group(2)
            names = []
            for p in split_args(params):
                nm = p.split("=")[0].strip()
                if re.fullmatch(r"[a-zA-Z_.][A-Za-z0-9_.]*", nm or ""):
                    names.append((nm, "=" in p))
            for idx, (nm, has_default) in enumerate(names):
                if not has_default:
                    continue
                prod = tests = 0
                for g, t in text.items():
                    if g == f:
                        continue
                    for cm in re.finditer(r"\b%s\s*\(" % re.escape(fn), t):
                        args = call_args(t, cm.end() - 1)
                        if args is None:
                            continue
                        named = any(re.match(r"\s*%s\s*=" % re.escape(nm), a)
                                    for a in args)
                        # POSITIONAL: the parameter is reached if the call
                        # supplies at least idx+1 arguments and none of the
                        # leading ones is named (which would shift positions).
                        positional = (len([a for a in args if a.strip()]) > idx
                                      and not any("=" in a for a in args[:idx + 1]))
                        if named or positional:
                            if g.startswith("tests/"):
                                tests += 1
                            else:
                                prod += 1
                verdict = ("used" if prod else
                           "tests only (%d)" % tests if tests else "never")
                if verdict != "used":
                    rows.append((f.replace(lib_dir + "/", ""), fn, nm, verdict))

    for f, fn, nm, why in sorted(rows):
        print("%-34s %-32s %-22s %s" % (f, fn, nm, why))
    never = sum(1 for r in rows if r[3] == "never")
    print(f"\n{len(rows)} candidates ({never} never passed). "
          "Read each one's rationale before cutting -- a documented injection "
          "point is not dead flexibility.")
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:2]))
