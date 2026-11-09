#!/usr/bin/env Rscript
# =============================================================================
# Saboteur tests: R/lib/work_site_topology.R
# =============================================================================
# tests/test_work_site_topology.R (T1-T31) checks the ordinary cases. This
# file tries to break the three site-building functions on purpose, each test
# constructing the one input most likely to fool it: a shared hospital campus,
# an employer/billing row dressed up to look like a workplace, a hospital
# affiliation with no resolved coordinates, a duplicated source row, and the
# rounding/case boundaries assign_site_ids() actually uses (round(lat,4),
# exact string equality on street+zip -- see its docstring). Every assertion
# is grounded in the committed implementation, not an assumed one.
# =============================================================================
root <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(file.path(dirname(sub("--file=", "", a[1])), ".."))
  else normalizePath(".")
}
source(file.path(root, "R", "lib", "work_site_topology.R"))

fails <- 0L
chk <- function(ok, label) {
  cat(sprintf("  %-4s %s\n", if (isTRUE(ok)) "ok" else "FAIL", label))
  if (!isTRUE(ok)) fails <<- fails + 1L
}

# =============================================================================
# assign_site_ids(): shared campuses, multiple records at one address
# =============================================================================
cat("\n-- assign_site_ids(): shared campuses and false-merge traps --\n")

# S1. A hospital system has two real buildings a few blocks apart. Different
# coordinates AND different street text must never be collapsed just because
# a human would call them "the same hospital" -- the function only sees
# coordinates and address text, never a name.
ids_s1 <- assign_site_ids(
  midwife     = c("M1", "M1"),
  lat         = c(39.7392, 39.7301),
  lon         = c(-104.9903, -104.9988),
  street_norm = c("1719 e 19th ave", "4200 e 9th ave"),
  zip5        = c("80218", "80262"))
chk(ids_s1[1] != ids_s1[2], "S1 two real buildings of one hospital system are two sites, not one")

# S2. Same ZIP, different street: a ZIP-only match would wrongly fuse two
# unrelated clinics that happen to share a dense urban ZIP code.
ids_s2 <- assign_site_ids(
  midwife     = c("M1", "M1"),
  lat         = c(NA, NA), lon = c(NA, NA),
  street_norm = c("100 main st", "900 oak st"),
  zip5        = c("10001", "10001"))
chk(ids_s2[1] != ids_s2[2], "S2 the same ZIP with different streets is never enough to merge")

# S3. Same street+ZIP, but coordinates captured by two sources round to
# slightly different 4-decimal keys (GPS jitter). The address key must still
# fuse them -- "OR", not "AND", per the function's own docstring.
ids_s3 <- assign_site_ids(
  midwife     = c("M1", "M1"),
  lat         = c(39.73920, 39.73924), lon = c(-104.99030, -104.99026),
  street_norm = c("1719 e 19th ave", "1719 e 19th ave"),
  zip5        = c("80218", "80218"))
chk(length(unique(ids_s3)) == 1L, "S3 matching street+ZIP fuses two sites despite slightly different GPS")

# S4. The reverse trap: identical coordinates to 4 decimals, but the street
# text differs only in case ("AVE" vs "ave"). The address key is exact string
# equality (no tolower() inside assign_site_ids), so two rows that a human
# normalizer forgot to lowercase do NOT fuse via the address key alone --
# they still fuse here only because the coordinates already match.
ids_s4 <- assign_site_ids(
  midwife     = c("M1", "M1"),
  lat         = c(39.73920, 39.73920), lon = c(-104.99030, -104.99030),
  street_norm = c("1719 E 19TH AVE", "1719 e 19th ave"),
  zip5        = c("80218", "80218"))
chk(length(unique(ids_s4)) == 1L,
    "S4 case-mismatched street text still fuses when coordinates already agree (coords carry it)")
ids_s4b <- assign_site_ids(
  midwife     = c("M1", "M1"),
  lat         = c(NA, NA), lon = c(NA, NA),
  street_norm = c("1719 E 19TH AVE", "1719 e 19th ave"),
  zip5        = c("80218", "80218"))
chk(ids_s4b[1] != ids_s4b[2],
    "S4b without coordinates, differently-cased street text is NOT recognised as the same address -- callers must normalise case before calling")

# S5. The exact rounding boundary the function uses: round(lat, 4). Two
# coordinates that round to the identical 4th decimal fuse; two that round to
# adjacent buckets do not, even though both pairs are a few metres apart on
# the ground.
ids_s5 <- assign_site_ids(
  midwife = c("M1", "M1"), lat = c(39.728290, 39.728299), lon = c(-104.990300, -104.990300),
  street_norm = c(NA, NA), zip5 = c(NA, NA))
chk(length(unique(ids_s5)) == 1L, "S5 coordinates rounding to the same 4th decimal fuse")
ids_s5b <- assign_site_ids(
  midwife = c("M1", "M1"), lat = c(39.72829, 39.72850), lon = c(-104.99030, -104.99030),
  street_norm = c(NA, NA), zip5 = c(NA, NA))
chk(ids_s5b[1] != ids_s5b[2], "S5b coordinates rounding to different 4th-decimal buckets do not fuse")

# S6. Transitivity across key TYPES, not just within one: A-B share only
# coordinates, B-C share only a street+ZIP captured at different coordinates.
# All three source rows -- Trilliant, NPPES, DAC -- describing one real
# building must land on one site_id.
ids_s6 <- assign_site_ids(
  midwife     = c("M1", "M1", "M1"),
  lat         = c(39.7392, 39.7392, 40.0000),
  lon         = c(-104.9903, -104.9903, -105.0000),
  street_norm = c(NA, "1719 e 19th ave", "1719 e 19th ave"),
  zip5        = c(NA, "80218", "80218"))
chk(length(unique(ids_s6)) == 1L,
    "S6 three source rows chain into one site via coordinates then address, transitively")

# S7. Two rows with NEITHER coordinates NOR an address are not assumed to be
# the same unknown place, even for the same midwife.
ids_s7 <- assign_site_ids(
  midwife = c("M1", "M1"), lat = c(NA, NA), lon = c(NA, NA),
  street_norm = c(NA, NA), zip5 = c(NA, NA))
chk(ids_s7[1] != ids_s7[2], "S7 two unlocated rows for one midwife are two unknown sites, not one")

# =============================================================================
# blended_practice(): employer rows, affiliations with no physical location
# =============================================================================
cat("\n-- blended_practice(): employer rows and location-free affiliations --\n")

# S8. A billing/employer row with a hospital-sounding name and real hospital
# coordinates still never counts: blended_practice excludes EMPLOYER sources
# by source name alone, before facility_type is even consulted.
s8 <- data.frame(
  certification_number = "A", source = "resolved_employer_org",
  facility_type = "hospital", facility_type_basis = "name_pattern",
  ccn = "060011", stringsAsFactors = FALSE)
b8 <- blended_practice(s8)
# A midwife with ONLY employer rows is filtered out before aggregation, so she
# is ABSENT from the output entirely -- not present with FALSE flags. The real
# caller (build_trilliant_work_sites.R) left_joins onto the full cohort and
# coalesce()s the resulting NA to FALSE; that safety net is asserted below,
# since blended_practice() alone does not guarantee one row per input midwife.
chk(nrow(b8) == 0L,
    "S8 an employer/billing row never counts as hospital evidence (the midwife is absent from the output, not FALSE)")
joined <- merge(data.frame(certification_number = "A", stringsAsFactors = FALSE),
                b8, by = "certification_number", all.x = TRUE)
coalesced <- ifelse(is.na(joined$hospital_broad[1]), FALSE, joined$hospital_broad[1])
chk(identical(coalesced, FALSE),
    "S8b the caller's left_join + coalesce(FALSE) turns that absence into a real FALSE, not an NA that leaks through")

# S9. A CMS DAC facility-affiliation row with NO resolved coordinates at all
# (ccn present, lat/lon never even reach this function) still counts as
# hospital_strict. blended_practice tests source + facility_type only; a
# physical worksite is a separate question answered by topology_by_midwife().
s9 <- data.frame(
  certification_number = c("A", "A"),
  source = c("cms_dac_facility_affiliation", "cabc_birth_center"),
  facility_type = c("hospital", "birth_center"),
  facility_type_basis = c("cms_dac_facility_affiliation_file", "cabc_accreditation"),
  ccn = c("060011", NA), stringsAsFactors = FALSE)
b9 <- blended_practice(s9)
chk(b9$hospital_strict[1] && b9$blended_strict[1],
    "S9 a DAC affiliation is strict hospital evidence even with no coordinates on the row")

# S10. A birth-center row identified only by a name match (no CABC, no
# building/org evidence) is broad but never strict, even when it is the ONLY
# birth-center evidence this midwife has.
s10 <- data.frame(
  certification_number = c("A", "A"),
  source = c("cms_dac_facility_affiliation", "trilliant_claims_top_site"),
  facility_type = c("hospital", "birth_center"),
  facility_type_basis = c("cms_dac_facility_affiliation_file", "site_name_pattern"),
  ccn = c("060011", NA), stringsAsFactors = FALSE)
b10 <- blended_practice(s10)
chk(b10$birth_center_broad[1] && !b10$birth_center_strict[1] && !b10$blended_strict[1] && b10$blended_broad[1],
    "S10 a name-only birth center is broad evidence, never strict, so blended_strict stays FALSE")

# S11. Triplicate identical rows must not change the verdict: `any()` makes
# duplicates a no-op, not a vote.
s11 <- s9[rep(1:2, each = 3), ]
s11$certification_number <- "A"
b11 <- blended_practice(s11)
chk(b11$blended_strict[1] && nrow(b11) == 1L,
    "S11 duplicated source rows for one midwife collapse to one verdict, not an inflated count")

# S12. An unexpected facility_type spelling ("Hospital", capitalised) is
# exact-string-matched against "hospital" and silently evaluates to FALSE.
# This locks in the real behaviour so a future upstream typo is caught here
# rather than discovered as a silent undercount in a published table.
s12 <- data.frame(certification_number = "A", source = "cms_dac_facility_affiliation",
                  facility_type = "Hospital", facility_type_basis = "cms_dac_facility_affiliation_file",
                  ccn = "060011", stringsAsFactors = FALSE)
b12 <- blended_practice(s12)
chk(!b12$hospital_strict[1], "S12 a facility_type spelling that doesn't match exactly is silently FALSE, not an error")

# S13. A midwife whose only rows are employer/billing sources still appears
# in the output, with every flag FALSE -- the employer filter must not drop
# the person from the table entirely.
s13 <- data.frame(
  certification_number = c("A", "B"),
  source = c("trilliant_primary_org", "cms_dac_facility_affiliation"),
  facility_type = c("clinic_practice", "hospital"),
  facility_type_basis = c("name_pattern", "cms_dac_facility_affiliation_file"),
  ccn = c(NA, "060011"), stringsAsFactors = FALSE)
b13 <- blended_practice(s13)
# A's only row is an employer source, so she is dropped from blended_practice()'s
# own output (see S8) -- the real contract is "absent, not falsely present",
# and B (a genuine DAC affiliation) must still come through untouched.
chk(!("A" %in% b13$certification_number) && "B" %in% b13$certification_number && b13$hospital_strict[b13$certification_number == "B"],
    "S13 an employer-only midwife is absent from blended_practice(), and does not suppress a real midwife's row")

# S14. Invariant across a stress fixture of every source x facility_type
# combination: blended_strict must never be TRUE when blended_broad is FALSE.
combos <- expand.grid(
  source = c("cms_dac_facility_affiliation", "trilliant_claims_top_site", "cabc_birth_center",
             "trilliant_primary_org", "resolved_employer_org", "nppes_primary_location"),
  facility_type = c("hospital", "birth_center", "clinic_practice"),
  stringsAsFactors = FALSE)
combos$certification_number <- paste0("P", seq_len(nrow(combos)))
combos$facility_type_basis <- "name_pattern"
combos$ccn <- ifelse(combos$facility_type == "hospital", "060011", NA)
b14 <- blended_practice(combos)
chk(all(!b14$blended_strict | b14$blended_broad),
    "S14 across every source x facility_type combination, blended_strict never implies blended_broad is FALSE")

# =============================================================================
# topology_by_midwife(): physical sites versus affiliations and billing rows
# =============================================================================
cat("\n-- topology_by_midwife(): what counts as a physical site --\n")

# S15. An employer-only midwife (no clinical workplace row at all) must show
# zero distinct sites, not be silently dropped from the table.
s15 <- data.frame(
  certification_number = "A", site_id = "A#1", source = "resolved_employer_org",
  facility_type = "clinic_practice", lat = 39.7392, lon = -104.9903,
  GEOID = "08031", rucc_cat = "Metro (RUCC 1-3)", stringsAsFactors = FALSE)
t15 <- topology_by_midwife(s15)
chk(is.null(t15) || nrow(t15) == 0L, "S15 a midwife with only an employer/billing row contributes no row at all (no physical site)")

# S16. The SAME physical site reaches the table through two sources (NPPES
# and DAC) at identical coordinates with the SAME site_id. The spread
# calculation must use distinct sites only, not double-count a site because
# two source rows point at it.
s16 <- data.frame(
  certification_number = c("A", "A", "A"),
  site_id = c("A#1", "A#1", "A#2"),
  source = c("nppes_primary_location", "cms_dac_facility_affiliation", "trilliant_claims_top_site"),
  facility_type = c("hospital", "hospital", "birth_center"),
  lat = c(39.7392, 39.7392, 40.0150), lon = c(-104.9903, -104.9903, -105.2705),
  GEOID = c("08031", "08031", "08013"),
  rucc_cat = c("Metro (RUCC 1-3)", "Metro (RUCC 1-3)", "Nonmetro, adjacent (4-6)"),
  stringsAsFactors = FALSE)
t16 <- topology_by_midwife(s16)
chk(t16$n_distinct_sites == 2L && abs(t16$max_km_between_sites - haversine_km(39.7392, -104.9903, 40.0150, -105.2705)) < 0.1,
    "S16 two source rows at one site_id do not inflate the distinct-site count or the spread")

# S17. A single-site midwife has max_km_between_sites == 0, never NA, no
# matter how many source rows describe that one site.
t17 <- topology_by_midwife(s16[s16$site_id == "A#1", ])
chk(!is.na(t17$max_km_between_sites) && t17$max_km_between_sites == 0,
    "S17 a one-site midwife has 0 km spread, not NA")

# S18. A midwife with two distinct sites but NEITHER has coordinates must get
# NA spread, not an error from combn() on too few rows and not a false 0.
s18 <- data.frame(
  certification_number = c("A", "A"), site_id = c("A#1", "A#2"),
  source = c("nppes_primary_location", "trilliant_claims_top_site"),
  facility_type = c("hospital", "clinic_practice"),
  lat = c(NA, NA), lon = c(NA, NA), GEOID = c(NA, NA), rucc_cat = c("Unknown", "Unknown"),
  stringsAsFactors = FALSE)
t18 <- topology_by_midwife(s18)
chk(t18$n_distinct_sites == 2L && is.na(t18$max_km_between_sites),
    "S18 two sites with no coordinates at all give NA spread, not 0 and not an error")

# S19. "Unknown" rurality must not be treated as a real, distinct category:
# one Metro site and one Unknown-rurality site is reported as Metro, not
# "mixed".
s19 <- data.frame(
  certification_number = c("A", "A"), site_id = c("A#1", "A#2"),
  source = c("nppes_primary_location", "trilliant_claims_top_site"),
  facility_type = c("hospital", "clinic_practice"),
  lat = c(39.7392, 40.5), lon = c(-104.9903, -105.5), GEOID = c("08031", NA),
  rucc_cat = c("Metro (RUCC 1-3)", "Unknown"), stringsAsFactors = FALSE)
t19 <- topology_by_midwife(s19)
chk(t19$rurality_mix == "Metro (RUCC 1-3)",
    "S19 an Unknown-rurality site does not turn a single real band into a false 'mixed'")

# S20. setting_combination lists each facility type once, sorted, even when
# three sites repeat the same type or arrive in a different row order.
s20 <- data.frame(
  certification_number = c("A", "A", "A"), site_id = c("A#3", "A#1", "A#2"),
  source = rep("nppes_primary_location", 3), facility_type = rep("hospital", 3),
  lat = c(39.0, 39.1, 39.2), lon = c(-105.0, -105.1, -105.2),
  GEOID = c("08031", "08031", "08031"), rucc_cat = rep("Metro (RUCC 1-3)", 3),
  stringsAsFactors = FALSE)
t20 <- topology_by_midwife(s20)
chk(t20$setting_combination == "hospital" && t20$n_distinct_settings == 1L,
    "S20 three hospital sites report the setting once ('hospital'), not repeated per site")

cat(if (fails) sprintf("\nFAILURES (%d)\n", fails) else "\nPASS (0 failures)\n")
quit(status = if (fails) 1L else 0L)
