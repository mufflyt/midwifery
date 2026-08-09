# Hall of Shame

Bugs written by Claude Code in this repo, kept because the failure modes repeat.
Each entry records how it *presented*, why it survived, and the generalizable
lesson. Ordered by how much damage it would have done if it had reached a
manuscript.

The pattern worth internalizing: **almost none of these threw an error.** They
produced plausible numbers, plausible maps, and plausible-looking verification
output. The dangerous class is not the crash — it is the silent success.

---

## Tier 1 — Wrong answers that looked right

### 1. Compared midwives to subspecialists and called them obstetricians

I built the congressional-district workforce comparison on
`step_2.5_final_cohort.rds` and described it as "ABOG board-certified OB/GYNs."
It is not. It is 7,616 **subspecialists** — MFM, REI, GYN-ONC, FPMRS, MIGS, CFP,
PAG. A midwife-to-gynecologic-oncologist ratio describes nothing clinical.

**How it presented:** 15 districts with "no OB/GYN," including FL-12, MI-05,
OK-03, TX-08/29/34. The output was internally consistent and formatted fine.

**How it was caught:** the owner said the comparison was apples-to-oranges. The
implausibility was visible in the numbers — populous mainland districts do not
have zero obstetricians — and I had printed that table without pausing on it.

**Corrected:** general OB/GYNs exist in `canonical_abog_npi_LATEST.csv`
(50,556 "Generalist"). Districts with none: **3**, all territories.

**Lesson:** a cohort file's *name* is not its *contents*. Check the distribution
of the classifying variable before describing a population. And when a result is
clinically implausible, that is the finding — stop and check, don't publish it
with a caveat.

### 2. Defined a population as "whoever happened to be geocoded"

`load_generalists()` originally started from the geocoded output file — 28,512
rows — and treated that as the generalist population. The roster has 50,556.

**Why it is insidious:** missingness became *invisible*, because the missing were
never in the denominator. Coverage looked like 100% of 28,512 rather than 56% of
50,556. Every district generalist rate was biased downward by a non-uniform
amount, and nothing in the output hinted at it.

**Corrected:** the loader starts from the roster and reports the shortfall.
Coverage went 56.4% → 99.6%, and **21,411 of the "missing" already had
coordinates** in `entire_80k_cohort_geocoded.rds` — the file had simply never
been joined. The undercount was incomplete source integration, not absent data.

**Lesson:** the denominator must come from the roster, never from the artifact
you are measuring. Locked in by `test_provider_loaders.R`.

### 3. Half the choropleth was the wrong color

The county map's bottom bin was `0.0–0.5`, so a county with **zero** midwives
rendered identically to one with 0.4 per 1,000. That is **1,619 of 3,109
counties** — over half the map — colored as "low" when the truth was "none."

For a study about workforce absence, that is the single most important class,
and I had dissolved it into a gradient.

**Corrected:** `mm_jenks_zero_scale()` — zero gets its own color and the label
"none"; positive values get Jenks natural breaks.

**Lesson:** zero is a category, not the low end of a scale. The canonical helper
already knew this, which leads to entry 8.

### 3b. "POS has no obstetric-service flag" — it has two

I searched the CMS Provider of Services header for `obst|matern|deliv|nursry|
nursery|neonat|birth|labor|nicu|perinat`, got nothing, and reported that POS's
473 columns contain no obstetric-service indicator. On that basis the county
analysis substituted AHRF's birthing-room count, and the claim went into a
pushed commit message.

POS column 221 is **`OB_SRVC_CD`** and column 461 is **`OB_GYN_SRGRY_SW`**.
Among hospitals: 7,270 coded `0`, 4,167 coded `1`, plus 296 and 447 at `2`/`3`.

My pattern never tried the obvious abbreviation. A concurrent session found it
immediately and geocoded 2,784 OB-service hospitals from it.

**Lesson:** a negative result from one grep is not a property of the data. When
the answer is "this dataset lacks X," check the codebook rather than trusting a
pattern you wrote from imagination — especially before making a substitution
decision that propagates into every downstream table.

### 3c. Reported coverage area that included the Great Lakes

The drive-time surfaces were clipped to the union of county polygons. Counties
extend into open water, so the coverage areas I reported -- 1,759,430 km2 within
30 minutes and 4,199,532 km2 within 60 -- counted lakes and coastal water as
ground within reach of a midwife. The Great Lakes are plainly shaded in the
screenshots; I looked at those maps repeatedly and did not see it.

Corrected with load_water_mask() from mufflyt/isochrones, which existed the
whole time:

| Band | Reported | Actual land | Water |
|---|---|---|---|
| 30 min | 1,759,430 km2 | 1,578,621 km2 | 180,809 (10.3%) |
| 60 min | 4,199,532 km2 | 3,656,267 km2 | 543,350 (12.9%) |

**Lesson:** clipping to an administrative boundary is not clipping to land, and
a coverage statistic denominated in area silently rewards water and empty
terrain. The population-weighted version (twostep::compute_band_tract_overlap)
would not have had this failure mode at all -- which is a second reason to
prefer it, beyond the one already noted.

### 3d. Excluded DC from the water clip, then used the bug to check for the bug

Having just fixed the water clip, I wrote:

```r
states <- setdiff(mufflyaccess::CONUS_STATE_ABBR, c("DC"))
```

A hand-written exception to a canonical constant, for no reason I can defend.
`DC_water_mask.fgb` was on disk the whole time, so the Potomac and Anacostia
stayed counted as drivable ground.

**The worse part is how I checked.** Asked which state was missing, I compared
the mask files on disk against `states` — my own already-filtered vector — got
an empty set, and reported "nothing is missing" twice. The filter was the bug,
and it was also the yardstick. Comparing against `CONUS_STATE_ABBR` instead
found it in one line.

Effect is 5 km² at 30 minutes, which is right for a 177 km² district and beside
the point: a silent exception of this shape is exactly as easy to write for
Michigan.

**Also fixed:** `Filter(Negate(is.null), wm)` silently dropped masks that failed
to read, and a state whose water goes unclipped looks identical to one whose
water is clipped. That is now a `stop()`. Same silent-success shape as entry 6.

**Lesson:** never check a filter's output with the filter. Compare against the
canonical source. And an exception to a canonical constant needs a written
reason at the moment you type it, or it should not be typed.

### 4. Counted 88 physicians twice

88 NPIs were labelled `Generalist` in the canonical roster *and* present in the
subspecialist cohort (32 as MFM). They were counted in both groups, inflating
`birth_attendants`.

**Lesson:** when two sources classify the same entities, test disjointness
explicitly. Two files agreeing on a total says nothing about whether they
agree row by row.

---

## Tier 2 — Silent infrastructure failures

### 5. A watcher that matched itself

```sh
until ! pgrep -f "generate_osmde_isochrones" >/dev/null; do sleep 60; done
```

`pgrep -f` matches the **full command line**, and the watcher's own argv contains
the pattern. It saw itself, looped forever, and the queued calibration never
ran. I reported "calibration is armed and will fire automatically" — twice.

**How it was caught:** only because the user asked for status a third time and I
listed actual processes instead of trusting `pgrep`.

**Fix:** `pgrep -f "calibrate_osmde_vs_ec[2]"` — the bracket does not match
itself. Or check the PID.

**Lesson:** a monitor that can observe itself is not a monitor. And "it's
running, I'll report when done" is a claim that needs verification, not
confidence.

### 6. Verification that verified nothing

The loop checking 14 copied files against their manifest SHA-256 printed:

```
verified OK: 0    mismatched: 0
```

Zero mismatches — and zero comparisons. The `IFS='|' read` parsing matched no
lines. Had I read only "mismatched: 0" I would have declared the copy verified.

**Lesson:** a check that can pass without doing anything is worse than no check.
Assert the *number of comparisons*, not just the number of failures.

### 7. Trusting a file's own key column

Archive releases wrote `location_key` at 5 decimal places; my catalog used 6.
Joining on it matched **zero rows** while the coordinates matched perfectly — and
the failure surfaced as an unrelated `[[<-.data.frame` error.

Same family: `x[, keep]` silently dropped the `sf_column` attribute; bands within
one release did not share a CRS; one release had `NA` CRS.

**Lesson:** derive keys from source values. A stored key is a claim about
formatting, not an identifier.

---

## Tier 3 — Presentation failures

### 8. Reimplemented a canonical function line for line

I wrote `jenks_zero_scale()` — a duplicate of `mm_jenks_zero_scale()` — and
separately re-derived canvas rendering, scale bars, and the map pane that keeps
points clickable above a choropleth. All existed in `mysterymaps_urogyn.R`.

This project has documented being bitten by exactly this three times (the gender
gate, credential helpers, `rank_one_to_one()`), where a fix applied to one copy
was a fix applied to none.

**Corrected:** `R/lib/mysterymaps_dep.R`, a path dependency that fails loudly
rather than falling back to a copy.

**Then I rationalised the leftovers.** Asked why the canonical builders were not
used for the coverage layers, I wrote: *"using them would mean changing a
canonical function to suit one caller."* That is the argument against every
library improvement ever made, and it was a defence of keeping private code.
The capability genuinely was missing — dissolved unions have no per-geography
value, so neither builder fit — but "the library can't express this" is a reason
to **extend the library**, not to fork quietly. `mm_add_coverage_surfaces()`,
`mm_register_base_legend()`, `mm_base_legend_switcher()` and
`mm_zoom_gated_labels()` now live in `mysterymaps_urogyn.R`, generic and unaware
of midwives.

**Which immediately paid for itself:** writing the generic legend switcher
surfaced the *same* defect in `mm_access_choropleth_map()` — two legends
registered with `group=` against `baseGroups`, so the urogyn maps have been
rendering both at once. Kept local, my workaround would have left that bug
shipping.

**Lesson:** look for the canonical helper before writing one; and when it does
not exist, the honest response is a patch upstream, not a paragraph explaining
why your caller is special. Both prompts came from the user, not from me.

### 9. Two color scales multiplied into mud

Translucent isochrone fills were stacked over a viridis choropleth as
checkboxes, both on by default. The result belonged to neither scale.

**Fix:** radio base groups — one metric at a time — which is what the canonical
builder does.

### 10. `addLegend(group=)` does not follow base groups

So all four legends rendered simultaneously, stacked down the right edge.
`group=` only tracks *overlay* groups. Fixed with CSS classes swapped on
`baselayerchange`.

### 11. `null`

```r
overlayGroups = if (INTERNAL) "Midwives (INTERNAL)" else NULL
```

R's `NULL` reached the widget and rendered a checkbox labelled **null**. Shipped
in a map I handed over.

### 12. Clustering by default

11,792 midwives replaced with orange bubbles reading "2941" — the data hidden
behind a number, requiring repeated zooming to learn anything.

### 13. Boilerplate in 2,700 popups

The sentence engine explains, for every county under WONDER's 100,000-resident
publication threshold, that WONDER does not publish it. True, and fired on ~87%
of counties, pushing each county's actual numbers below the fold. The caveat
belongs once, in the notes. Also: a notes panel occupying a quarter of the
screen.

---

## Tier 4 — Sloppiness

- **`sprintf("... 99.9% ...")`** — unescaped `%` in a format string. Crashed the
  build. At least this one failed loudly.
- **"1471 of 2945"** — printed a completion total by summing the queue length and
  the accumulated results.
- **Deduplicated a routing queue on `(location_key, latitude, longitude)`** when
  `location_key` is those coordinates rounded to 6 dp. Six pairs of midwives
  differing by under a centimetre survived as separate rows, so a
  **volunteer-run public server** was asked for six polygons it had already
  sent. Small, but it was someone else's bandwidth.
- **Compared dissolved coverage area to CONUS land area** when the union
  included Alaska and Hawaii.

---

## What the guards caught

Not everything failed. These were designed to fail loudly, and did:

- **Range guard on `nonhosp_birth_share`** — my proposed construct-validity
  measure produced out-of-range values in **695 counties**, proving its
  numerator and denominator do not share a reporting universe. Values were set
  `NA` rather than clipped, so the incompatibility stayed visible instead of
  becoming a plausible-looking column.
- **Privacy assertion in the map builder** — `stopifnot(length(u) == 1L)` after
  the dissolve. If the union ever yields more than one feature, the output is
  per-origin geometry and the build stops.
- **Explicit "not examined" reporting** in the recovery finalizer — 32 origins
  were silently unexamined in the first run; they now count as failing and are
  named, so a gap in the audit cannot read as a pass.
- **The polygon validation gate** — cut naive proximity recovery from 77.1% to
  33.2%, keeping 620 unsound origins out of the analysis.
- **Arithmetic sanity** — "664 origins from an input of 557" was impossible on
  its face, which is how the duplicate-row fan-out was found.

The difference between Tier 1 and this section is not care. It is whether the
check was written *before* the result was believed.

### 14. A "water mask" that was the whole state

**Symptom.** Midwives in Kansas had dots but no drive-time coverage around them.
The gate put it at 583 of 11,742 CONUS midwives (5.0%) outside the surface
dissolved from their own isochrones, concentrated in Missouri (117), Iowa (112),
Kansas (79), West Virginia (53) and Arkansas (39).

**Cause.** Not the isochrones. The land clip was subtracting land. Five states
carried a single-feature water mask covering **102–104% of the entire state** —
a state outline, not water:

| state | mask km² | state land km² | mask ÷ census water |
|---|---|---|---|
| WV | 65,123 | 62,756 | 133× |
| MO | 185,134 | 180,540 | 74× |
| IA | 148,906 | 145,746 | 137× |
| AR | 140,659 | 137,732 | 45× |
| KS | 217,346 | 213,100 | 162× |

For comparison the working masks are a few percent of their state: New York 8.8%,
Minnesota 4.9%, Colorado 0.0%. File sizes said the same thing — NY is 495 KB of
real water detail, these five are 7–14 KB.

`st_difference(union, water)` therefore erased **every isochrone in five states**.
The map showed the rural interior as having no midwife access at all.

**Upstream cause.** The high-resolution mask downloader logged
`"Empty response, assuming complete"` hundreds of times. Those five states never
received an HR mask — 30 states have one, these five do not — and a fallback
wrote the state boundary as the mask. An empty response was treated as success.

**Why nothing caught it.** Subtracting too much geometry does not error, does not
warn, and leaves no hole a reader would recognise as a defect. It removes
shading, and the map still looks plausible. `n_origins_dissolved` counted what
went into the dissolve, never what survived the clip, so the provenance field
agreed with the broken output.

**Fix.** Two gates in `build_midwifery_isochrone_map.R`:

1. **Containment** — every input polygon must be represented in the dissolved
   surface (4,714/4,714 at 30 min).
2. **Mask inversion** — a mask larger than 5× its state's census `AWATER` is not
   water; it is excluded from the clip, loudly.

Excluded rather than fatal: a surface that includes some open water in five
states is far better than one that erases those states, and the masks cannot be
regenerated from this repository.

**The false positive that shaped the test.** The first gate compared mask area to
**land** area and flagged Michigan at 68%. Michigan's boundary contains the Great
Lakes, so a mask that size is *correct* there — excluding it would have let the
surface run across Lake Michigan, which is the exact failure the clip exists to
prevent. Measured against census `AWATER` the cases separate cleanly: Michigan
0.95×, the inverted five 45–162×. **Pick the denominator that distinguishes the
failure from the legitimate extreme, not the one that is easiest to reach.**

**Result.** Water removed at 30 minutes fell from 180,809 km² to 7,448 km²; the
surface grew from 1,578,621 km² to 1,751,982 km²; midwives outside their own
coverage fell from 583 to 180, and the remainder is scattered (IL 31, CA 28,
NY 28, FL 26) rather than clustered in five states.

**Four wrong diagnoses preceded the right one**, each stated with more confidence
than it deserved: 1,033 locations without isochrones (union-count arithmetic);
63.8% uncovered (exact-coordinate join against origins matched within 5 km); 7%
lost inside `st_union` (measured against the clipped surface, not the dissolve);
and a +11.4% recovery from batched unioning (pre-clip area compared with
post-clip area). The lesson is narrow and practical: when a spatial result looks
wrong, test the **point against the polygon** before theorising about the
pipeline that produced it.
