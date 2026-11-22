# Technical appendix: what reading `midwife_panel.csv` costs

## Why this exists

`midwife_panel.csv` is the largest intermediate this repository produces, and
almost every analysis script reads it. On 2026-11-21 a parse walk over every
tracked R file outside `tests/` counted **28 reads of it that parse all
thirteen columns**, across 24 files, against exactly **one** read that named
the columns it needed — `compare_all_sources_mysteryroster.R:159`, which had
been doing it right all along.

That is not a performance curiosity. A full-width read of this file costs
**60.8 s**; the same read naming three columns costs **12.1 s**. Fourteen of
those 24 scripts are in `rebuild_frozen_dependents.R`'s plan, so a rebuild
spent an extrapolated 18.2 minutes inside `readr` on one file for no reason.

This appendix records what was measured, how, what was changed, and — more
importantly — **which of these claims a CI gate can enforce and which it
cannot**. The full review is [`Review_AI_performance.qmd`](../Review_AI_performance.qmd);
the measurement script is
[`tools/measure_panel_read_cost.R`](../tools/measure_panel_read_cost.R).

## 1. The file, and which build of it

Measured 2026-11-22 with `ARM=inventory`:

| | |
|---|---|
| size | 544,742,809 bytes (115 bytes/row) |
| rows | 4,735,546 provider-years |
| distinct NPIs | 472,327 |
| columns | 13 |
| snapshot years | 20, **2007–2026**, none missing |
| taxonomy split | `midwife` 253,895 rows / 21,633 NPIs; `nursing` 4,481,651 rows / 451,913 NPIs |

The two taxonomy NPI counts sum to more than 472,327 because an NPI can appear
under `nursing` in one snapshot year and `midwife` in another. That is a
documented property of the panel, not a defect — the split happens *across*
years, never within one.

Exactly one snapshot per year, each a single observation date:

| year | rows | NPIs | snapshot | | year | rows | NPIs | snapshot |
|---|---|---|---|---|---|---|---|---|
| 2007 | 92,042 | 92,042 | 2007-11-12 | | 2017 | 229,279 | 229,279 | 2017-04-09 |
| 2008 | 99,126 | 99,126 | 2008-05-12 | | 2018 | 251,019 | 251,019 | 2018-07-08 |
| 2009 | 112,845 | 112,845 | 2009-06-07 | | 2019 | 266,840 | 266,840 | 2019-04-07 |
| 2010 | 120,993 | 120,993 | 2010-02-08 | | 2020 | 291,795 | 291,795 | 2020-07-12 |
| 2011 | 136,619 | 136,619 | 2011-04-11 | | 2021 | 308,281 | 308,281 | 2021-04-11 |
| 2012 | 150,452 | 150,452 | 2012-04-09 | | 2022 | 330,825 | 330,825 | 2022-04-10 |
| 2013 | 164,910 | 164,910 | 2013-04-07 | | 2023 | 353,165 | 353,165 | 2023-04-09 |
| 2014 | 179,981 | 179,981 | 2014-04-13 | | 2024 | 376,381 | 376,381 | 2024-04-07 |
| 2015 | 195,784 | 195,784 | 2015-04-12 | | 2025 | 418,964 | 418,964 | 2025-11-09 |
| 2016 | 212,096 | 212,096 | 2016-04-10 | | 2026 | 444,149 | 444,149 | 2026-08-09 |

### This is not the build the freeze was made from

**Read this before quoting any number above in a manuscript.** The panel is
gitignored and not regenerable from a fresh clone, and two builds of it with
the same twenty snapshot years can still differ:

| | the build measured here | the build the freeze used |
|---|---|---|
| SHA-256 | `6b9696ce8919…` | `40c45ce1161f…` |
| rows | 4,735,546 | 4,747,648 |
| distinct NPIs | 472,327 | 451,793 |
| snapshot years | 20, 2007–2026, none missing | 20, 2007–2026, none missing |

The second column is what `artifacts/linkage_manifest.json` records under
`inputs/nppes_panel`, and it is what every published cohort count rests on.
The first is a later rebuild that happens to be on this machine. **Timings are
transferable between the two — same size class, same schema, same shape — and
counts are not.** The equivalence proofs below are properties of the reader,
not of the build, so they hold for either.

This is also why `tools/measure_panel_read_cost.R` prints the file's size on
every run and refuses to substitute a fixture when the panel is absent.

## 2. How these numbers were measured

Four traps, each of which produced a wrong number first. They are in the
script's header too, because the next person to measure this will hit them.

1. **One arm per process.** Peak memory is only attributable if nothing else
   ran in the same session, and arms in one session pay for each other's
   garbage collection: the full-width read measures **60.8 s alone and 89.3 s**
   alongside five others. Every figure quoted as an arm is a lone
   `Rscript --vanilla` process.
2. **Peak memory is OS RSS, not `gc()`.** The first pass of this measurement
   computed a peak from `gc()`'s `max used` column with the Ncells and Vcells
   byte widths reversed — Ncells are 56 bytes, Vcells 8 — and reported a
   3,501 MB peak that does not exist. Every peak here is
   `/usr/bin/time -l`'s *maximum resident set size*.
3. **A readr read that is never touched has not happened.** readr 2.x returns
   lazy ALTREP columns, so timing `read_csv()` and stopping measures the cost
   of *not* reading the file. Every timed arm forces materialisation inside the
   timed region.
4. **Equivalence is checked, not asserted.** Every narrowing is compared with
   `identical()` against the same columns of the full-width read, over every
   row.

The DuckDB arms open their connection through `duckdb_connect()`
(`R/lib/medicare_duckdb.R`), the same factory `build_midwife_panel.R:317`
uses, so the encoding bootstrap and the spill directory are configured
identically in the measurement and in the code measured. The first version
of the harness called `DBI::dbConnect(duckdb::duckdb())` directly;
`tests/ci_duckdb_ingestion_bootstrap.R` refused it, correctly.

Host: 8-core macOS, 8.0 GB RAM, R 4.5.2, readr 2.2.0, duckdb 1.5.5.

### The ratio is the claim; the seconds are not

Re-running the committed harness after the review produced a *different*
full-width number, and the reason is worth recording rather than hiding:

| full-width read of the same file | elapsed |
|---|---|
| review anchor, all 13 columns materialised, quiet machine | 60.8 s |
| harness, all 13 materialised, machine loaded by the other arms | 178.0 s |
| harness, 3 columns materialised (current method), run 1 | **41.0 s** |
| harness, 3 columns materialised (current method), run 2 | **41.8 s** |
| harness, narrowed read, same session as the two above | **10.1 s** |

Two separate effects, neither of them noise:

1. **How much the timed region materialises.** The first version of
   `force_cols()` touched every column it was given, so the full-width arm paid
   to materialise ten columns the narrowed arm never has. That is real work, but
   it is work *the scripts being fixed never do either* — they parse thirteen
   columns and use three. The harness now forces the same three in both arms, so
   the arms differ in parse width and nothing else. The `types` arm forces all
   thirteen in both arms on purpose, because there the question is inference,
   not width.
2. **Memory pressure on an 8 GB machine.** A 1.2–1.5 GB arm competing with
   another 1.2 GB arm does not degrade gracefully. Repeated runs in one sitting
   are tight (41.0 s and 41.8 s); runs separated by other work are not
   comparable.

So: **quote the ratio, not the seconds.** Full-width costs roughly 4–5× a
narrowed read of this file, reproducibly, and that is what the fix removes.
Every absolute figure in this appendix is from one sitting on one loaded
laptop, and a re-measurement that lands on a different second count has not
contradicted anything.

## 3. Measured anchors

| arm | elapsed | persistent | peak RSS |
|---|---|---|---|
| `read_csv(cols(.default = "c"))` — 13 columns | **60.8 s** | 534.1 MB | 1,186 MB |
| `read_csv(col_select = <3 used>)` | **12.1 s** | 137.2 MB | 1,197 MB |
| `read_csv(cols(<10 × col_skip>))` | 12.4 s | 137.2 MB | 1,172 MB |
| `read.csv(colClasses = "character")` | 72.5 s | 534.0 MB | — |
| DuckDB `read_csv_auto` + `GROUP BY` | **4.4 s** | ~0 | 313 MB |

The last row is the ceiling on all of this: the file can be reduced without
being materialised in R at all.

## 4. What was changed

| finding | before | after | proof |
|---|---|---|---|
| **F1** the summary tail read the panel back in base R | 210.9 s, 1,169 MB peak | **6.7 s, 593 MB** | identical four values |
| **F2** eleven reads parsed 13 columns to keep 3 | 60.8 s each | **12.1 s each** | `identical()`, every row |
| **F4** malformed rows discarded, nothing counted | no number moved | reject count per release | `store_rejects = true` |
| **F5** the resume path read all 544 MB | 72.5 s, 534 MB | **5.0 s, 217 MB peak** | same 20 years |
| **F6** `guess_max = Inf` with a partial spec | 96.8 s | **43.0 s** | `identical()`, whole frame |

The three cleanly isolated savings total **807 s — 13.5 minutes — per full
pass** over the tree. F6's is excluded from that total because it was only
measured in-process.

### F1, in detail

`build_midwife_panel.R` writes the panel one snapshot year at a time
(`write.table(..., append = !first)`), so it never holds the 4.7 M-row result.
The summary tail then read it all back to print four numbers, and 96.8 s of
that went into one statement:

```r
changed <- aggregate(last_name ~ npi, panel, function(x) length(unique(x)))
```

`aggregate()`'s formula method calls an R closure **once per group**, and there
are 472,327 groups. The replacement is one query on the connection the script
already had open, and returns the same `4735546 / 472327 / 507559 / 33657`.

### F2, in detail

Eleven reads across nine files, in four distinct column sets. Each set was
checked by reading the file both ways in one process:

| `col_select` | sites | `identical()` |
|---|---|---|
| `c(npi, snapshot_year, practice_state)` | 7 | TRUE |
| `c(npi, snapshot_year, practice_zip)` | 1 | TRUE |
| `c(npi, snapshot_year, snapshot_date, practice_state)` | 1 | TRUE |
| `c(npi, deactivation_date)` | 1 | TRUE |

Seventeen full-width reads remain, in seventeen files, every one of them
recorded in `tests/ci_read_width_baseline.txt` with a reason. They are not
oversights: the three address-comparison scripts genuinely need the four
`practice_*` columns, the two name-matching scripts need the name columns, and
`provenance_manifest.R` only wants a row count it should be getting from
DuckDB. Eight of the seventeen are in the rebuild plan, so the extrapolated
readr cost of one `REBUILD_APPLY` pass fell from **18.2 minutes to 8.1**.

## 5. Three things that are NOT true

Stated here because each one is the obvious thing to say while fixing this, and
each one is false.

- **Narrowing a read does not save memory.** Peak RSS is 1,186 MB full-width
  and 1,197 MB narrowed. readr streams all 544 MB through its parse buffer
  whichever columns it keeps; what shrinks is the frame you are left holding
  (534.1 MB → 137.2 MB), not the high-water mark. Any "this fixes our memory
  problem" framing of `col_select` is wrong.
- **F6 is not a narrowing.** Both geographic-persistence scripts still read all
  thirteen columns, because they use most of them. What went away is the
  *type-inference pass*: `guess_max = Inf` is **not** ignored when the spec is
  partial (`.default = col_guess()`), so readr scanned all 4,735,546 rows to
  guess twelve types before parsing them. The thirteen named types are the ones
  that scan arrives at, `npi` and both snapshot columns as **doubles** —
  naming `npi` as character because an NPI is obviously an identifier would
  silently zero every join against a linkage file that is itself read with
  guessing on. `reconcile_linkage.R` keeps its `guess_max = Inf` and its
  recorded reason: a column that is NA for most rows and carries a real
  ten-digit value late in the file.
- **F3 was deliberately not done.** Seven sites recompute the same
  `(npi, year, state)` reduction; materialising it as an artifact takes 25.0 s
  once against 85.8 MB on disk. It stays closed because F2 already took those
  sites to 12.1 s each, leaving perhaps a minute per pass, while the artifact
  would add a provenance sidecar, a staleness relationship and an edge in the
  rebuild graph. Reach for it only if a measured `REBUILD_APPLY` pass says
  rebuild wall-clock still matters.

## 6. The gate, and the three ways it lied first

`tests/ci_read_width.R` refuses a **new** full-width read against a
shrink-only baseline keyed on file and count — not `file:line`, because line
numbers churn on unrelated edits. `tests/test_read_width_detect.R` plants the
defect back in **twelve** cases and requires the gate to die on each.

The detector exists because the gate reported a clean tree three times while
missing real reads. All three failures are the same shape — **a smaller number
than the truth, reported as success** — and all three are now saboteurs:

1. **RW5: the path arrives through a variable.** The resolver indexed
   `regmatches()` output against a mask built from the unfiltered line vector.
   `regmatches()` drops non-matching elements, so the two went out of
   alignment and four files reaching the panel through `PANEL` /
   `PANEL_PATH` / `Sys.getenv()` were silently missed. All three spellings are
   planted, so fixing one cannot pass.
2. **RW8: the file listing broke.** Run from inside `tests/`, `ci_tracked()`
   returned only `tests/`-relative paths, the `^tests/` exclusion removed every
   one of them, and the gate printed `PASS` having scanned **zero files**. The
   gate now asks `git -C <root> ls-files` and refuses a scan of fewer than 50
   non-test R files, because a number near zero means the listing broke, not
   that the habit was fixed.
3. **RW10: the path was assigned across lines.** The resolver was a
   single-line regex, so it never saw `build_midwife_panel.R`'s `out_path`,
   which is assigned over five lines inside a `Sys.getenv()` whose default
   carries a comment. **The two most expensive reads in the repository — F1 and
   F5, 283 s between them — were invisible to the gate that exists to find
   exactly them.** It now resolves assignments from the parse tree it was
   already walking.

A fourth case is not a lie but a boundary. The gate failed on
`tools/measure_panel_read_cost.R` the moment that file was added — correctly,
since it reads the panel full-width several times. It is the *instrument*, not
the waste: timing a full-width read requires performing one, exactly as a
fixture under `tests/` plants the defect on purpose. The exemption is that one
path and not `tools/`, because excluding the directory would hide the next
harvester that reads the panel badly — and **RW11 plants a full-width read in a
different `tools/` file and requires it to be refused**, so the exemption
cannot be quietly read as covering more than it says.

The pattern worth keeping: every one of these was found by *mutating the gate
and watching it stay green*, which is the same discipline as
[`APPENDIX_checks_that_cannot_fail_2026-11-20.md`](APPENDIX_checks_that_cannot_fail_2026-11-20.md).

## 7. The claim CI cannot check

The panel is gitignored, so **no gate can verify any count in §1 against the
file itself** — CI has never seen it and never will. That is a real hole: the
README described the panel as "annual snapshots 2007–2025, 443,623 NPIs" for
long enough that a second appendix had already noticed and written down a
correction (451,793) which was itself stale by the time this one was written.

What *can* be checked is prose against the committed manifest, which is the
discipline `ci_data_regression_guard.R` D6 and D13 already apply to the roster
and freeze counts. **D14** now pins the README's panel figures to
`artifacts/linkage_manifest.json`'s `inputs/nppes_panel` block, so the inventory
prose and the manifest cannot drift apart again without CI saying so. The
numbers in §1 of this appendix are explicitly *not* gated, are dated, and carry
the file hash they came from.

## 8. Reproducing this

```sh
# one process per arm; prints the loop, including the /usr/bin/time -l wrapper
ARM=driver Rscript tools/measure_panel_read_cost.R

# or a single arm
ARM=inventory /usr/bin/time -l Rscript tools/measure_panel_read_cost.R
ARM=equiv     /usr/bin/time -l Rscript tools/measure_panel_read_cost.R
```

Arms: `inventory`, `full`, `select`, `skip`, `baseR`, `tail`, `resume`,
`types`, `equiv`. `MIDWIFE_PANEL` overrides the path, as it does for the
scripts that read the panel in anger. The script writes nothing and modifies no
repository file.

The gates that keep this from regressing:

```sh
Rscript tests/test_read_width_detect.R   # 11 saboteurs: the gate still detects
Rscript tests/ci_read_width.R            # no new full-width read of the panel
Rscript tests/test_build_midwife_panel.R # 20 fixture cases through the builder
Rscript tests/ci_data_regression_guard.R # D14: README's panel figures vs manifest
```
