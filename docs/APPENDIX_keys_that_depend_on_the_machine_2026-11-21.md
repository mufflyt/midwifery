# Appendix — keys that depend on the machine that built them

**2026-11-21.** Three call sites in this repository folded accented characters
with `base::iconv(x, to = "ASCII//TRANSLIT")`. That function's output is not
defined by R; it is whatever the host C library returns. macOS ships libiconv
and Linux ships glibc, and on this input they disagree:

```
$ R --vanilla -q -e 'iconv("Muñoz", from = "", to = "ASCII//TRANSLIT")'
[1] "Mu~noz"          # macOS, aarch64-apple-darwin20, R 4.5.2
                      # glibc returns "Munoz"
```

Two of the three sites then ran the result through a character class that
replaces anything outside `[A-Z0-9 ]` **with a space**. So the combining mark
libiconv leaves behind became a separator:

| input | key on macOS | key on a Linux runner |
|---|---|---|
| `Muñoz` | `MU NOZ` | `MUNOZ` |
| `José` | `JOS E` | `JOSE` |

These were not display strings. `normalize_text()` in `amcb_license_bridge.R`
feeds `normalize_person_name()` and `normalize_city()`, and
`normalize_license_number_padded()` feeds `make_license_key()` — the
deterministic join key the whole AMCB-to-NPPES bridge is built on. The same
midwife, recorded identically in two sources, got two different keys depending
on which machine ran the script.

## Why no test caught it

This is the part worth generalising. Every obvious check passes:

- **Unit tests pass.** They run on one machine and assert that machine's answer.
- **CI passes.** It runs on one machine too, consistently — a different one.
- **The two never disagree in view of each other.** Nothing compares a key built
  on the author's laptop against the same key built on a runner, because
  artifacts are built in one place and consumed in another.
- **Reviewing the line does not help.** `iconv(to = "ASCII//TRANSLIT")` reads
  like a deterministic string operation. The non-determinism is in a C library
  three layers down, and the function's own help page describes `//TRANSLIT` as
  platform-dependent in a sentence most readers have never needed.

The defect is only visible if you either run the same input on two operating
systems, or know the libiconv/glibc difference in advance. That makes it a
**documentation problem, not a testing problem** — which is why it is written
down here rather than only fixed.

## The repository had already hit this, once, and the knowledge did not travel

`R/lib/work_site_topology.R:30` carries this comment, predating the fix:

> `# macOS iconv transliterates "ñ" to "~n" and glibc to "n"; dropping the`
> `# marks it can leave behind makes both give "n".`

followed by `gsub("[~^`\"]", "", x)`. So `county_key()` was safe. The other
three sites were written by people who had not read that comment, and two of
them were wrong. A hard-won fact recorded in one file's comment protects that
file and nothing else.

## The rule

**Do not use `iconv(to = "ASCII//TRANSLIT")` to build anything that is compared,
joined, or persisted.** Use a transform whose output is fixed by its own
specification:

```r
stringi::stri_trans_general(x, "Latin-ASCII")   # ICU, bundled with stringi
```

ICU's `Latin-ASCII` is a versioned, documented transform; it returns `Munoz`,
`Jose`, `Asa` and `SS` for `ß` on every platform. `stringi` arrives with
`stringr`, which this repository already depends on everywhere, so this adds no
dependency. It was already the convention at
`expand_former_name_candidates.R:127` — a third precedent nobody had generalised.

`iconv()` remains fine for what it is good at: best-effort display, or a path
like `county_key()` that deliberately strips whatever marks come back.

## What the fix moved, and what it did not

`normalize_text()`'s keys **changed** for accented inputs: `Muñoz` now keys as
`MUNOZ` on every machine instead of `MU NOZ` on one of them. That is the point
of the fix, and it will move linkage counts for accented names.

`normalize_license_number_padded()`'s keys **did not change at all**. Its strip
is `[^A-Z0-9]` with no space in the class, so it deleted the combining mark
rather than separating on it — the same accident that protects `county_key()`.
It was replaced anyway, because the protection was incidental: widening that
character class by one space, which is the only difference between it and
`normalize_text()`, would have reintroduced the platform dependence silently.
Equivalence was verified over sixteen license shapes including `ß`, `Ø` and `Å`;
every key was identical before and after.

## How it is held closed

`tests/test_review_fixes_saboteurs.R`, saboteurs R1–R7. The determinism itself
cannot be asserted at runtime on a single machine — on a glibc runner the old
code returns the *right* answer, so a behavioural assertion would pass there and
let the defect back in. So the suite splits the law in two:

- **Behavioural**, and true on every platform: an accented spelling and its
  unaccented spelling must produce one key. Saboteurs plant "no fold at all"
  (`MU OZ`) and "drop the character" (`MUOZ`); a near miss shows a base-R
  `chartr()` fold passing, so the law is the fold and not one implementation.
- **Static**: no string literal in `amcb_license_bridge.R` asks `iconv` to
  transliterate. Read from `STR_CONST` parse tokens rather than raw text,
  because this file's own fix comment names the call it removed.

## Related

- `R/lib/work_site_topology.R:30` — the same divergence, handled by stripping
  marks instead.
- `R/lib/org_names.R:28` — the sibling lesson about apostrophes in keys, also
  recorded in one file's comment and also not generalised. Person-name keys
  still space apostrophes, so `O'Brien` and `OBrien` do not match. That is a
  policy change rather than a determinism bug, so it was deliberately left for
  a shadow-arm comparison rather than folded into this fix.
