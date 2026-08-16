#!/usr/bin/env Rscript
# =============================================================================
# AMCB certified midwives -> NPI, using the existing isochrones machinery
# =============================================================================
#
# This deliberately does NOT introduce another fuzzy matcher. It reuses the
# stable pipeline logic from:
#
#   scripts/match_enthealth_to_npi.R   -- itself adapted from
#   R/canonical_abog_npi_pipeline_STABLE.R
#
# Specifically reused, not reimplemented:
#   norm_name(), first_initial()   name normalisation
#   compute_match_score()          NOT used: it collapses categorical identity
#                                  evidence into one number, and this cohort has
#                                  no location/DOB to make a finer scale mean
#                                  anything. Ordered evidence classes instead.
#   rank_one_to_one()              greedy bijection with deterministic tiebreak
#   safe_pct()                     reporting helper
#
# ENTHealth is the right precedent: a scrape with names but no NPI, matched
# against an NPPES pool. AMCB is the harder case of the same shape, because it
# publishes no location at all -- so the zip/city/phone signals that pipeline
# leans on are unavailable, and the discriminating evidence is name plus the
# fact that every candidate in the panel is already a midwife.
#
# Candidates come from the 2007-2025 historical NPPES panel rather than the
# current registry, so midwives who have since left NPPES remain matchable.
# For each matched NPI the MOST RECENT panel appearance supplies the location,
# and nppes_location_year travels beside it: for someone last seen in 2014 this
# is their last observed practice location, not their current one.
#
# Every AMCB row is preserved. Unmatched rows keep NA geography.
#
# Output: artifacts/amcb_npi_matched.csv
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble); library(stringdist); library(tidyr)
  library(digest); library(jsonlite)
})

# Resolved before anything sources a sibling file: the ENT script below does a
# setwd() into the isochrones root, so a path relative to getwd() taken after
# that point would resolve into the wrong repository.
root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}

ISO <- Sys.getenv("ISOCHRONES_DIR", path.expand("~/isochrones"))
Sys.setenv(PIPELINE_LOAD_ONLY = "1")   # suppress the script's auto-main()
ent_script <- file.path(ISO, "scripts", "match_enthealth_to_npi.R")
if (!file.exists(ent_script)) {
  stop(sprintf("Cannot find %s -- set ISOCHRONES_DIR", ent_script), call. = FALSE)
}
# The script guards that here::here() resolves to the isochrones root, because
# every source() inside it depends on that. Sourcing from another repo trips the
# guard, so source it from its own root and come straight back. (here caches the
# root it resolves; nothing here calls here() afterwards.)
local({
  owd <- setwd(ISO)
  on.exit(setwd(owd), add = TRUE)
  suppressWarnings(suppressMessages(source(file.path("scripts",
                                                     "match_enthealth_to_npi.R"))))
})
for (fn in c("norm_name", "first_initial", "compute_match_score",
             "rank_one_to_one", "safe_pct")) {
  if (!exists(fn)) stop(sprintf("%s() not available from %s", fn, ent_script),
                        call. = FALSE)
}
cat("reusing:", paste(c("rank_one_to_one", "safe_pct"), collapse = ", "), "\n")

# NAME NORMALISATION IS NOT TAKEN FROM THE ENT SCRIPT (2026-08-10).
#
# norm_name() and first_initial() are still sourced above -- rank_one_to_one()
# and the ENT script's own internals rely on them -- but this pipeline must NOT
# use them for AMCB. norm_name() is toupper(trimws(...)) and nothing more, so
# it PRESERVES accents rather than transliterating them:
#
#   norm_name("Álvarez") -> "ÁLVAREZ"   first_initial(...) -> "Á"
#
# Every strategy below joins on exact first name or exact first initial, so an
# accented roster name could not reach its unaccented NPPES spelling by any
# route. Measured in the frozen linkage: of the 27 roster rows with non-ASCII
# names, sensitivity_fuzzy runs 26% against 1.5% cohort-wide (the accent
# survives to strategy 3 and scores as one Levenshtein edit) and unmatched runs
# 30% against 10.4%.
#
# R/amcb_name_keys.R delegates to the CANONICAL normalize_string(), which
# already transliterates correctly. It is a key builder, not a second
# normaliser. See tests/test_amcb_name_normalization.R.
source(file.path(root_dir, "R", "amcb_name_keys.R"))
source(file.path(root_dir, "R", "amcb_match_rules.R"))
source(file.path(root_dir, "R", "amcb_resolver.R"))
cat("name keys: amcb_name_key() via canonical normalize_string()",
    "(transliterating)\n")

PANEL   <- Sys.getenv("MIDWIFE_PANEL", "midwife_panel.csv")
ROSTER  <- "midwives.csv"
OUT_DIR <- "artifacts"
dir.create(OUT_DIR, showWarnings = FALSE)
YEAR_FLOOR <- suppressWarnings(as.integer(Sys.getenv("PANEL_YEAR_MAX", "")))

# Every A/B variant must write its own artifact. Keying the filename on the
# year cap alone was not enough: the taxonomy A/B varied the PANEL instead, so
# both arms wrote amcb_npi_matched.csv and the second silently replaced the
# first -- the same defect twice, once per dimension. The name now derives from
# every input that changes the result, so a new dimension cannot reintroduce it
# without also changing the filename.
# Artifact naming must encode EVERY dimension that can alter the linkage, not
# just the one that varied most recently. Keying on the year window alone was
# not enough: the taxonomy A/B varied the PANEL, both arms wrote the same file,
# and the second silently replaced the first. Same defect twice, once per
# dimension. Naming now derives from the panel definition AND the year window,
# and a run refuses to clobber an existing artifact without an explicit flag.
# Every invocation gets a unique id, recorded in a sidecar manifest beside the
# artifact. Twice now a failed run left an older file in place and its numbers
# were read as if fresh; a consumer must be able to PROVE which invocation
# produced what it is reading, not infer it from a timestamp.
RUN_ID <- Sys.getenv("MATCH_RUN_ID", sprintf(
  "amcbmatch_%s_%s", format(Sys.time(), "%Y%m%dT%H%M%S"),
  paste(sample(c(letters, 0:9), 6, replace = TRUE), collapse = "")))
RUN_STARTED <- Sys.time()

OUT <- Sys.getenv("MATCH_OUT", "")   # resolved after the panel is read,
                                     # because the name depends on its content

panel_definition <- function(panel_df) {
  classes <- unique(panel_df$tax_class)
  if (all(classes == "midwife")) "midwifery" else "midwifery-plus-nursing"
}
year_window <- function(panel_df) {
  if (!is.na(YEAR_FLOOR)) sprintf("through-%d", YEAR_FLOOR)
  else paste(range(panel_df$snapshot_year, na.rm = TRUE), collapse = "-")
}

npi_luhn_ok <- function(npi) {
  ok <- grepl("^[0-9]{10}$", npi)
  if (!any(ok, na.rm = TRUE)) return(ok & FALSE)
  digits <- lapply(npi, function(x) if (grepl("^[0-9]{10}$", x))
    as.integer(strsplit(paste0("80840", substr(x, 1, 9)), "")[[1]]) else NULL)
  vapply(seq_along(npi), function(i) {
    d <- digits[[i]]
    if (is.null(d)) return(FALSE)
    idx <- rev(seq_along(d))
    dbl <- d; odd <- which(idx %% 2 == 1)
    dbl[odd] <- dbl[odd] * 2
    dbl[dbl > 9] <- dbl[dbl > 9] - 9
    (10 - (sum(dbl) %% 10)) %% 10 == as.integer(substr(npi[i], 10, 10))
  }, logical(1))
}

# --- Inputs ------------------------------------------------------------------
# THE DEFECT THIS GUARDS AGAINST (2026-08-08). Two base-R behaviours combined
# to manufacture identity evidence:
#
#   paste(NA_character_, "")  ->  "NA"     (a fabricated middle initial "N")
#   nzchar(NA_character_)     ->  TRUE     (missing read as "information present")
#
# Every absent middle name became "N" and matched every other absent middle
# name: all 18,397 candidate pairs reported middle agreement, and evidence
# class 2 (exact name, no middle info) was empty. norm_name() and toupper() are
# NOT at fault -- they propagate NA correctly.
blank_na <- amcb_blank_na                      # transliterating; see above

# Never use a naked nzchar() to ask whether identity information exists.
has_name_information <- amcb_has_name_information

amcb <- read_csv(ROSTER, show_col_types = FALSE) %>%
  mutate(amcb_id = certification_number,
         # The name as AMCB published it, kept verbatim beside the keys. A
         # crosswalk that shows only the normalised form cannot be audited:
         # a reviewer has no way to see that "ALVAREZ" came from "Álvarez".
         amcb_name_original = trimws(paste(
           coalesce(first_name, ""), coalesce(middle_name, ""),
           coalesce(last_name, ""))),
         amcb_customer_id = customer_id,
         last_clean  = blank_na(last_name),
         # AMCB fuses middle names into first_name ("Julie Ann"): the first
         # token is the given name, the rest is middle.
         first_raw   = blank_na(first_name),
         first_clean = amcb_split_first(first_name)$given,
         mid_from_first = amcb_split_first(first_name)$middle_from_first,
         # paste() renders NA as the literal "NA"; blank_na() has already
         # mapped absence to "" so nothing here can fabricate an initial.
         middle_clean = trimws(paste(blank_na(middle_name), mid_from_first)),
         first_init  = coalesce(amcb_first_initial(first_clean), ""),
         mid_init    = substr(middle_clean, 1, 1))

panel_raw <- read_csv(PANEL, col_types = cols(.default = "c")) %>%
  mutate(snapshot_year = suppressWarnings(as.integer(snapshot_year)))
if (!is.na(YEAR_FLOOR)) {
  panel_raw <- filter(panel_raw, snapshot_year <= YEAR_FLOOR)
  cat(sprintf("panel restricted to snapshots <= %d\n", YEAR_FLOOR))
}

if (!"tax_class" %in% names(panel_raw)) panel_raw$tax_class <- "midwife"
panel <- panel_raw %>%
  filter(!is.na(npi), npi_luhn_ok(npi)) %>%
  # The panel arrives UPPER(TRIM())-ed by the DuckDB extract, but NOT
  # transliterated -- and the 2007-2017 dissemination files are latin-1, so
  # accented NPPES spellings are genuinely present on this side too. Both sides
  # must pass through the same key builder or the fix is only half applied.
  mutate(nppes_last_clean  = blank_na(last_name),
         nppes_first_clean = blank_na(first_name),
         nppes_first_init  = coalesce(amcb_first_initial(nppes_first_clean), ""),
         nppes_mid_init    = substr(blank_na(middle_name), 1, 1),
         # Retained verbatim for the crosswalk's evidence columns.
         nppes_last_raw   = last_name,
         nppes_first_raw  = first_name,
         nppes_middle_raw = middle_name)

# Candidate identities: one row per (NPI, name spelling) so every historical
# surname is matchable, not just the current one.
# An NPI that ever carried a midwifery taxonomy is stronger evidence for an
# AMCB certificant than one that only ever appears as a nurse. Nursing codes
# are in the pool because a CNM must hold RN licensure and may enumerate under
# either, but the pool is now 21x larger (443,623 NPIs vs 20,849), so treating
# both alike would let name collisions with unrelated nurses outvote real
# midwives.
npi_class <- panel %>%
  group_by(npi) %>%
  summarise(npi_tax_class = if (any(tax_class == "midwife")) "midwife" else "nursing",
            .groups = "drop")

identities <- panel %>%
  distinct(npi, nppes_last_clean, nppes_first_clean, nppes_first_init, nppes_mid_init) %>%
  left_join(npi_class, by = "npi")
cat("candidate NPIs by taxonomy class:\n"); print(table(npi_class$npi_tax_class))

# Most recent appearance per NPI supplies the geography.
latest <- panel %>%
  filter(!is.na(practice_state) & nzchar(practice_state)) %>%
  arrange(desc(snapshot_year)) %>%
  group_by(npi) %>% slice(1) %>% ungroup() %>%
  # Business PRACTICE location (build_midwife_panel.R selects
  # provider_first_line_business_practice_location_address), never the mailing
  # address. The source fields ride along: publishing city/state is fine, but
  # validating them later is impossible without what they were derived from.
  # NPPES-side identity evidence rides along with the geography, taken from
  # the SAME most-recent appearance. It is deliberately NOT added to the
  # identity table above: that table is keyed on normalised names, and joining
  # raw spellings into it would split one candidate NPI into several rows and
  # silently inflate every candidate count.
  transmute(npi,
            nppes_first_name = nppes_first_raw,
            nppes_middle_name = nppes_middle_raw,
            nppes_last_name = nppes_last_raw,
            nppes_credential = credential,
            nppes_city = practice_city, nppes_state = practice_state,
            nppes_zip = practice_zip,
            nppes_practice_address = practice_address,
            nppes_location_year = snapshot_year)

if (!nzchar(OUT)) {
  OUT <- file.path(OUT_DIR, sprintf("amcb_npi_linkage_panel-%s_years-%s.csv",
                                    panel_definition(panel), year_window(panel)))
}
if (file.exists(OUT) && !identical(Sys.getenv("MATCH_OVERWRITE"), "1")) {
  stop(sprintf(paste("%s already exists. Overwriting it would replace another",
                     "arm's numbers with this one's -- exactly how the year and",
                     "taxonomy A/B arms lost their artifacts. Set",
                     "MATCH_OVERWRITE=1 to replace it deliberately."), OUT),
       call. = FALSE)
}
# Config smoke test, run BEFORE any matching. A patch once swallowed OUT's
# definition and the run died only after building the candidate pool; these
# assertions cost nothing and fail in the first second instead.
local({
  def <- panel_definition(panel); win <- year_window(panel)
  stopifnot(nzchar(OUT), nzchar(def), nzchar(win))
  stopifnot(grepl(def, basename(OUT), fixed = TRUE),
            grepl(win, basename(OUT), fixed = TRUE))
  alt <- file.path(OUT_DIR, sprintf("amcb_npi_linkage_panel-%s_years-%s.csv",
                                    if (def == "midwifery") "midwifery-plus-nursing"
                                    else "midwifery", win))
  stopifnot(!identical(normalizePath(OUT, mustWork = FALSE),
                       normalizePath(alt, mustWork = FALSE)))
  cat("config smoke test: OK (name carries both dimensions and is spec-unique)\n")
})
cat(sprintf("panel definition: %s | year window: %s\noutput: %s\n",
            panel_definition(panel), year_window(panel), OUT))

cat(sprintf("AMCB rows: %s | panel identities: %s (%s NPIs, snapshots %s)\n",
            format(nrow(amcb), big.mark = ","), format(nrow(identities), big.mark = ","),
            format(n_distinct(identities$npi), big.mark = ","),
            paste(range(panel$snapshot_year, na.rm = TRUE), collapse = "-")))

# --- Staged matching ---------------------------------------------------------
# Flags feed compute_match_score() unchanged. There is no zip/city/phone signal
# to give it -- AMCB has no location -- so those stay 0 and the score is driven
# by name agreement plus the specialty signal, which is 1 for every candidate
# because the panel is midwives by construction.
# specialty_signal is deliberately 0, not 1. Every candidate in this pool is a
# midwife by construction, so a constant flag cannot favour one NPI over
# another -- scoring it would only inflate confidence uniformly and disguise
# how thin the discriminating evidence actually is.
base_flags <- function(df, strategy, method) {
  df %>% mutate(match_strategy = strategy, match_method = method,
                specialty_signal = 0L, zip_match = 0L, city_match = 0L,
                phone_match = 0L)
}
# Maximum attainable score with name evidence alone (exact_last 40 + exact_first
# 20); the ENT pipeline's 108 assumed zip/city/phone/specialty signals we do not
# have, so scaling by it would understate nothing and overstate confidence.
MAX_NAME_SCORE <- 60

# --- Candidate generation: EVERY strategy, for EVERY row ---------------------
# Previously each strategy ran only on the residual of the last, so a row that
# matched exactly at strategy 1 never generated its fuzzy-surname candidates.
# That is why STACEY WALDEN silently vanished from the candidate set when an
# exact STACEY ALLEN appeared, and why CONFLICT_MARGIN could never fire: the
# candidates it was meant to compare could not coexist. Generate the complete
# plausible set and let evidence decide.
# A blank name is not a name: joining "" to "" would be a fabricated exact match.
identities <- identities %>% filter(has_name_information(nppes_last_clean),
                                   has_name_information(nppes_first_clean))
amcb_named <- amcb %>% filter(has_name_information(last_clean),
                              has_name_information(first_clean))

s1 <- amcb_named %>%
  inner_join(identities, by = c("last_clean" = "nppes_last_clean",
                                "first_clean" = "nppes_first_clean"),
             relationship = "many-to-many") %>%
  mutate(exact_last = 1L, exact_first = 1L, first_init_ok = 1L, lv_last = 0L,
         # THE NAME VARIANT THAT ACTUALLY WON (2026-08-10). An NPI may appear
         # under several surnames across snapshots -- 1891167631 is WILLIAMS in
         # early years and WRIGHT later. The match is made on the historical
         # spelling, but nppes_last_name reports the MOST RECENT one, so a
         # reviewer comparing the two sees a surname mismatch on a method
         # called "exact_last_first" and reasonably concludes it is a false
         # match. Recording the winning variant is what makes the match
         # checkable. Here the join keys collapse, so the variant IS the AMCB
         # key by construction.
         nppes_matched_last = last_clean, nppes_matched_first = first_clean) %>%
  base_flags(1L, "exact_last_first")

s2 <- amcb_named %>%
  inner_join(identities, by = c("last_clean" = "nppes_last_clean",
                                "first_init" = "nppes_first_init"),
             relationship = "many-to-many") %>%
  filter(first_clean != nppes_first_clean) %>%   # s1 already holds exact-first
  # Surname is the join key so it collapses; the given name does NOT match
  # exactly here, so the NPPES side of it is the informative half.
  mutate(exact_last = 1L, exact_first = 0L, first_init_ok = 1L, lv_last = 0L,
         nppes_matched_last = last_clean, nppes_matched_first = nppes_first_clean) %>%
  base_flags(2L, "exact_last_first_initial")

s3 <- amcb_named %>%
  inner_join(identities, by = c("first_clean" = "nppes_first_clean"),
             relationship = "many-to-many") %>%
  mutate(lv_last = stringdist(last_clean, nppes_last_clean, method = "lv")) %>%
  filter(lv_last > 0, lv_last <= 2, nchar(last_clean) >= 5) %>%
  # Given name is the join key; the surname is fuzzy, so the NPPES spelling of
  # it is exactly what a reviewer needs to see to judge the match.
  mutate(exact_last = 0L, exact_first = 1L, first_init_ok = 1L,
         nppes_matched_last = nppes_last_clean, nppes_matched_first = first_clean) %>%
  base_flags(3L, "fuzzy_last_exact_first")

# --- Strategy 5: shared surname COMPONENT + exact given name -----------------
# THE GAP THIS CLOSES (2026-08-10). AMCB and NPPES disagree about how compound
# surnames are recorded -- AMCB "MCCARTHY-DERVIN" against NPPES "MCCARTHY", or
# AMCB splitting "HARVEY CAPISTA" across its middle and last fields where NPPES
# keeps it whole. No strategy above can span a DROPPED component: strategy 3's
# Levenshtein ceiling of 2 cannot cross seven missing characters, so these fail
# as "no candidate at all" rather than as a weak match. Measured in the
# preceding crosswalk: hyphenated surnames run 27.1% unmatched against 9.8%
# unhyphenated, a 2.8x gap over 791 roster rows -- roughly 8x the population
# the accent fix reached.
#
# WHY THIS IS THE WEAKEST CLASS AND NOT A PEER OF THE OTHERS. Discarding half a
# compound surname discards real discriminating information: every SMITH-JONES
# becomes joinable to every SMITH sharing a given name. This is a recall
# instrument with a genuine precision cost, so it enters at the BOTTOM of the
# evidence order (class 5). It can only resolve someone for whom nothing
# stronger exists, and it lands in its own sensitivity tier -- never in
# primary_midwifery. Particles and sub-4-character tokens are excluded by
# amcb_surname_tokens(); see tests T14-T20.
amcb_tok <- amcb_surname_token_table(amcb_named$last_clean, amcb_named$amcb_id) %>%
  rename(amcb_id = id, surname_token = token)
ident_indexed <- identities %>% mutate(.ident_row = row_number())
ident_tok <- amcb_surname_token_table(ident_indexed$nppes_last_clean,
                                      ident_indexed$.ident_row) %>%
  rename(.ident_row = id, surname_token = token)
cat(sprintf("surname component tokens: %s AMCB, %s NPPES identity rows\n",
            format(nrow(amcb_tok), big.mark = ","),
            format(nrow(ident_tok), big.mark = ",")))

s5 <- amcb_named %>%
  inner_join(amcb_tok, by = "amcb_id", relationship = "many-to-many") %>%
  inner_join(ident_indexed %>% inner_join(ident_tok, by = ".ident_row",
                                          relationship = "many-to-many"),
             by = c("first_clean" = "nppes_first_clean",
                    "surname_token" = "surname_token"),
             relationship = "many-to-many") %>%
  # Exact-surname pairs are already class 1/2. Only genuinely PARTIAL surname
  # agreement is new information here.
  filter(last_clean != nppes_last_clean) %>%
  select(-.ident_row, -surname_token) %>%
  distinct() %>%
  mutate(exact_last = 0L, exact_first = 1L, first_init_ok = 1L,
         lv_last = NA_integer_, component_last = 1L,
         nppes_matched_last = nppes_last_clean, nppes_matched_first = first_clean) %>%
  base_flags(5L, "surname_component_exact_first")
cat(sprintf("strategy 5 candidate pairs: %s\n", format(nrow(s5), big.mark = ",")))

# --- Evidence, kept as components rather than collapsed into one number ------
# Two people who are both exact first+last matches, with no middle name,
# location or DOB to separate them, ARE indistinguishable. A finer score would
# manufacture certainty rather than measure it. So identity strength is an
# ORDERED CLASS of name evidence, and taxonomy is a separate axis that decides
# the tier -- never the identity.
#
#   1  exact first + last + compatible middle
#   2  exact first + last, no useful middle information
#   3  exact last + first initial
#   4  fuzzy last + exact first
#   5  surname component + exact first (WEAKEST -- see strategy 5 above)
#
# Class 5 sorts BELOW 4 numerically because resolution takes min(class) as the
# strongest evidence; a partial surname must never outrank a whole one.
candidates_prefilter <- bind_rows(s1, s2, s3, s5) %>%
  mutate(
    component_last = coalesce(component_last, 0L),
    mid_both   = has_name_information(mid_init) &
                 has_name_information(nppes_mid_init),
    mid_match  = as.integer(mid_both & mid_init == nppes_mid_init),
    mid_conflict = as.integer(mid_both & mid_init != nppes_mid_init),
    name_evidence_class = case_when(
      exact_last == 1L & exact_first == 1L & mid_match == 1L ~ 1L,
      exact_last == 1L & exact_first == 1L                   ~ 2L,
      exact_last == 1L & first_init_ok == 1L                 ~ 3L,
      component_last == 1L                                   ~ 5L,
      TRUE                                                   ~ 4L),
    taxonomy_axis = npi_tax_class)
candidates <- candidates_prefilter %>%
  filter(mid_conflict == 0L)   # a recorded middle-initial conflict still vetoes

# RULED IN, OR MERELY NOT RULED OUT? (2026-08-10)
#
# Review of the class-5 census found ten matches where several pool members
# shared the given name AND the joining surname token. The veto above had
# already reduced each to a single candidate, which looked like successful
# discrimination -- and for three of them it was: the survivor's middle initial
# AGREED with the roster's.
#
# For the other seven it was not. Kelly Kathleen Clark-Mattox is the clearest
# case: eight KELLY + CLARK NPIs exist, seven carry a recorded middle initial
# (A, J, N, A, C, S, O), none is K, so all seven were vetoed. The survivor is
# the one NPI with NO middle name at all. It was not ruled IN by agreeing with
# KATHLEEN; it was the only one that could not be ruled OUT.
#
# That is a materially weaker claim than the evidence class implies, and it is
# invisible downstream because the surviving row looks identical to a genuine
# unique match. Restricted to class 5, where the surname evidence is already
# partial, such a match is quarantined rather than published.
vetoed_c5_pairs <- candidates_prefilter %>%
  filter(name_evidence_class == 5L, mid_conflict == 1L) %>%
  distinct(amcb_id, vetoed_npi = npi)

cat("\ncandidates by name_evidence_class x taxonomy:\n")
print(as.data.frame(count(candidates, name_evidence_class, taxonomy_axis)))

# Full candidate audit table: every plausible pair survives here even when it
# loses, so adding a candidate source can never make a known candidate vanish.
cand_audit <- candidates %>%
  transmute(amcb_id, npi, name_evidence_class, taxonomy_axis, match_method,
            exact_last, exact_first, first_init_ok, mid_match, lv_last,
            first_year = NA_integer_, last_year = NA_integer_)
write_csv(cand_audit, file.path(OUT_DIR, "linkage_candidate_audit.csv"), na = "")

# --- Resolution: identity first, taxonomy second -----------------------------
# The resolution rules live in R/amcb_resolver.R so they can be tested without
# person-level inputs. tests/test_amcb_resolver_permutation.R runs them over a
# hostile fixture in 300 randomised candidate orderings. Inline here, they could
# only be exercised by running this whole pipeline, which needs gitignored data.
per_npi <- amcb_per_npi(candidates)

pool_stats <- amcb_pool_stats(per_npi)

resolved <- amcb_resolve_best_class(per_npi, pool_stats)

quarantined_ids <- amcb_quarantined_ids(candidates, resolved)


cat("\nresolved by best name-evidence class:\n")
print(as.data.frame(count(resolved, name_evidence_class, taxonomy_axis)))
cat(sprintf("indistinguishable at best class (quarantined): %s\n",
            format(length(quarantined_ids), big.mark = ",")))

# CONFLICT_MARGIN is gone. It expressed a numeric question about categorical
# evidence, and its zero-conflict behaviour was structural (staged generation
# meant the candidates it compared never coexisted), not validation of the
# value 12. Ordered evidence classes replace it.
diag_pools <- pool_stats %>% mutate(quarantined = amcb_id %in% quarantined_ids)
write_csv(diag_pools, file.path(OUT_DIR, "linkage_pool_diagnostics.csv"), na = "")

# Only now enforce one NPI to one person, over candidates that were already
# individually identifiable. Record contested NPIs before the bijection prunes
# them, since that count is itself a data-quality signal.
contested <- resolved %>% count(npi) %>% filter(n > 1)

matched <- resolved %>%
  # rank_one_to_one() ranks on method_priority, score_total then
  # confidence_score. Feed it the evidence class as the score so the bijection
  # prefers the strongest identity evidence, not an arbitrary row order.
  mutate(enthealth_id = amcb_id,
         score_total = 5L - name_evidence_class,
         match_strategy = name_evidence_class) %>%
  rank_one_to_one() %>%
  transmute(amcb_id, npi, npi_match_method = match_method,
            nppes_matched_last, nppes_matched_first, nppes_mid_init,
            npi_tax_class = taxonomy_axis, name_evidence_class,
            npi_match_resolution = resolution,
            npi_match_confidence = round(confidence_score, 4),
            npi_match_score = 5L - name_evidence_class,
            match_strategy)   # candidate counts come from pool_stats, once

# A VETOED ALTERNATIVE MUST BE A DIFFERENT PERSON (2026-08-10).
# The first version of this counted n_distinct(npi[mid_conflict == 1L]) and
# demoted three matches that were fine. An NPI appears once per name variant
# per snapshot, so a single person recorded with a middle initial in one year
# and without it in another supplies BOTH a conflicting and a non-conflicting
# candidate row -- and the conflicting one was counted as evidence against the
# match it belongs to. NPI 1609834951 (JOANNE ANDERSON, middle L then absent)
# and 1548261456 (ANASTASIA OTT HALLISEY, middle M. then absent) were each
# vetoed by themselves. Excluding the matched NPI leaves only genuinely rival
# people, which is what the guard was ever meant to count.
# Delegated to count_rival_npis() in R/amcb_match_rules.R rather than written
# inline: the rule is exactly what was got wrong, and inline it can only be
# tested by a nine-minute full run plus an artifact diff. See G3 in
# tests/test_amcb_gates.R, which pins BOTH directions -- a self-variant is not
# a rival, a different NPI is.
mid_veto_stats <- count_rival_npis(
  as.data.frame(vetoed_c5_pairs),
  as.data.frame(matched %>% select(amcb_id, npi))) %>%
  rename(n_mid_vetoed_c5 = n_rival_npis)

# Rows identifiable on name but which lost the bijection to a stronger claim.
lost_bijection <- setdiff(unique(resolved$amcb_id), matched$amcb_id)
ambiguous_ids <- union(quarantined_ids, lost_bijection)

out <- amcb %>%
  # The normalised keys are PUBLISHED, not discarded. They were dropped here
  # before, which made the crosswalk unauditable: a reviewer looking at a
  # surprising match could not see which strings were actually compared, and
  # the accent defect was invisible in the artifact for exactly that reason.
  rename(normalized_first_name = first_clean,
         normalized_middle_name = middle_clean,
         normalized_last_name = last_clean) %>%
  select(-first_raw, -mid_from_first, -first_init, -mid_init) %>%
  left_join(matched, by = "amcb_id") %>%
  left_join(latest, by = "npi") %>%
  # pool_stats joined exactly ONCE: it is the single source of candidate counts.
  left_join(pool_stats, by = "amcb_id") %>%
  left_join(mid_veto_stats, by = "amcb_id") %>%
  mutate(n_mid_vetoed_c5 = coalesce(n_mid_vetoed_c5, 0L),
         # Ruled in, or merely not ruled out. TRUE when a class-5 match
         # survived ONLY because it carried no middle initial to conflict,
         # while recorded alternatives were vetoed by theirs.
         resolved_by_absence_c5 = !is.na(npi) & name_evidence_class == 5L &
           n_mid_vetoed_c5 > 0L & !has_name_information(nppes_mid_init)) %>%
  # Demotion runs AFTER the flag exists and BEFORE status is derived. Both
  # halves matter: an earlier placement reads a column that does not exist yet,
  # and a later one leaves the row holding an NPI while calling itself
  # quarantined.
  mutate(npi_demoted_absence_c5 = resolved_by_absence_c5,
         # Keep the demoted NPI before dropping it. Demotion removes the CLAIM
         # that this is the person; it does not make the candidate we found
         # disappear, and the row keeps that candidate's nppes_city/state/zip.
         # Without this line those fields describe an NPI recorded nowhere on
         # the row -- a city with no identity behind it, which is the inversion
         # contract A4 now fails on and which produced 8 such rows in the
         # current crosswalk.
         #
         # The held-out class-5 rows already do exactly this, which is why 156
         # of them carry geography coherently and these 8 did not: same
         # situation, recorded two different ways.
         class5_candidate_npi = if_else(resolved_by_absence_c5, npi,
                                        NA_character_),
         npi = if_else(resolved_by_absence_c5, NA_character_, npi),
         npi_tax_class = if_else(npi_demoted_absence_c5, NA_character_, npi_tax_class),
         name_evidence_class = if_else(npi_demoted_absence_c5,
                                       NA_integer_, name_evidence_class)) %>%
  mutate(npi_match_status = case_when(
    npi_demoted_absence_c5 ~ "ambiguous_unruled_out_component",
    !is.na(npi) & npi_tax_class == "nursing" ~ "matched_nursing_taxonomy",
    !is.na(npi)                  ~ "matched",
    amcb_id %in% quarantined_ids ~ "ambiguous_tied_names",
    amcb_id %in% lost_bijection  ~ "ambiguous_contested_npi",
    TRUE                         ~ "unmatched")) %>%
  mutate(across(c(n_candidates_pre_rank, n_midwifery_candidates,
                  n_nursing_only_candidates), ~ coalesce(.x, 0L))) %>%
  # "no plausible NPI exists" and "plausible NPIs exist but identity is
  # ambiguous" are different kinds of missingness and must stay separable.
  mutate(has_candidate = n_candidates_pre_rank > 0,
         linkage_tier = case_when(
           # Fuzzy identity evidence is sensitivity-only whatever the taxonomy.
           # Its own tier, not folded into sensitivity_fuzzy: the two have
           # different failure modes and must stay separable.
           !is.na(npi) & name_evidence_class == 5L  ~ "sensitivity_name_component",
           !is.na(npi) & name_evidence_class == 4L  ~ "sensitivity_fuzzy",
           !is.na(npi) & npi_tax_class == "nursing" ~ "sensitivity_nursing",
           !is.na(npi)                              ~ "primary_midwifery",
           npi_demoted_absence_c5                   ~ "quarantined",
           grepl("^ambiguous", npi_match_status)    ~ "quarantined",
           TRUE                                     ~ "unmatched"),
         # candidate_count is the pool BEFORE resolution -- how many NPIs were
         # ever plausible for this person. Reporting the post-bijection count
         # would always be 0 or 1 and would hide every ambiguity.
         candidate_count = n_candidates_pre_rank,
         # TRUE when the spelling that produced the match is not the spelling
         # NPPES currently reports for that NPI. Without this a reviewer reads
         # a legitimate name change as a false match; with it, the row explains
         # itself. Compared on the normalised key, not the raw string, so an
         # accent alone can never raise the flag.
         nppes_name_changed_since_match = !is.na(npi) &
           !is.na(nppes_matched_last) & !is.na(nppes_last_name) &
           blank_na(nppes_matched_last) != blank_na(nppes_last_name),
         # ambiguity_flag separates "we could not tell which person" from "we
         # found nobody". Those are different failures and are routinely
         # conflated into a single unmatched rate.
         ambiguity_flag = case_when(
           npi_match_status == "ambiguous_tied_names"   ~ "tied_on_name_evidence",
           npi_match_status == "ambiguous_contested_npi" ~ "lost_bijection_to_stronger_claim",
           npi_match_status == "ambiguous_unruled_out_component" ~
             "class5_survived_only_by_carrying_no_middle_initial",
           !is.na(npi) & n_at_best_class > 1L            ~ "resolved_but_pool_not_unique",
           is.na(npi) & has_candidate                    ~ "candidates_existed_none_resolved",
           TRUE                                          ~ "none"),
         # A sentence a human can check, built from the evidence actually used.
         match_reason = case_when(
           is.na(npi) & !has_candidate ~ "no NPPES midwifery/nursing candidate shared this name",
           is.na(npi) ~ sprintf("%d candidate(s), %d tied at best evidence class %s; not resolvable on name alone",
                                candidate_count, n_at_best_class, best_evidence_class),
           TRUE ~ sprintf("%s; evidence class %d (%s); %s taxonomy; %d candidate(s), %d at best class",
                          npi_match_method, name_evidence_class,
                          # Five entries for five classes. A four-entry vector
                          # would silently yield NA for class 5 and print
                          # "evidence class 5 (NA)" in the auditable column.
                          c("exact first+last+middle initial", "exact first+last, no middle info",
                            "exact last + first initial", "fuzzy last + exact first",
                            "surname component + exact first")[name_evidence_class],
                          npi_tax_class, candidate_count, n_at_best_class)))

stopifnot(nrow(out) == nrow(amcb), !any(duplicated(out$amcb_id)))
stopifnot(all(out$linkage_tier %in% c("primary_midwifery", "sensitivity_nursing",
                                      "sensitivity_fuzzy", "sensitivity_name_component",
                                      "quarantined", "unmatched")),
          sum(table(out$linkage_tier)) == nrow(amcb),
          !any(out$linkage_tier == "primary_midwifery" &
                 out$npi_tax_class == "nursing", na.rm = TRUE))
# Atomic publish: a failed or half-finished run must not leave something that
# looks like a valid linkage artifact. Write to a temp path, then rename only
# after every assertion above has passed.
tmp_out <- paste0(OUT, ".tmp", Sys.getpid())
write_csv(out, tmp_out, na = "")
if (!file.rename(tmp_out, OUT)) {
  unlink(tmp_out)
  stop(sprintf("could not publish %s", OUT), call. = FALSE)
}

# Sidecar manifest: proves provenance of the bytes just published.
manifest <- list(
  run_id = RUN_ID,
  run_started_utc = format(RUN_STARTED, tz = "UTC", usetz = TRUE),
  run_finished_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
  artifact = basename(OUT),
  artifact_sha256 = digest::digest(file = OUT, algo = "sha256"),
  artifact_rows = nrow(out),
  source_script_sha256 = digest::digest(file = "match_amcb_to_npi.R", algo = "sha256"),
  panel = basename(PANEL),
  panel_sha256 = digest::digest(file = PANEL, algo = "sha256"),
  panel_definition = panel_definition(panel),
  year_window = year_window(panel),
  columns = names(out))
jsonlite::write_json(manifest, paste0(OUT, ".manifest.json"),
                     auto_unbox = TRUE, pretty = TRUE)
cat(sprintf("run_id: %s\nmanifest: %s\n", RUN_ID, paste0(basename(OUT), ".manifest.json")))

# --- Report ------------------------------------------------------------------
n <- nrow(out); nm <- sum(!is.na(out$npi))
cat(sprintf("\n================ AMCB -> NPI ================\n"))
cat(sprintf("total AMCB rows            : %s\n", format(n, big.mark = ",")))
cat(sprintf("unique certification numbers: %s\n", format(n_distinct(out$amcb_id), big.mark = ",")))
cat(sprintf("unique (last, first) names : %s\n",
            format(nrow(distinct(out, last_name, first_name)), big.mark = ",")))
cat(sprintf("NPI matched                : %s (%s)\n", format(nm, big.mark = ","), safe_pct(nm, n)))
cat(sprintf("ambiguous (lost bijection) : %s\n", format(length(ambiguous_ids), big.mark = ",")))
cat(sprintf("unmatched                  : %s (%s)\n",
            format(sum(out$npi_match_status == "unmatched"), big.mark = ","),
            safe_pct(sum(out$npi_match_status == "unmatched"), n)))
cat("\nby match method:\n"); print(count(filter(out, !is.na(npi)), npi_match_method, sort = TRUE))
if ("npi_tax_class" %in% names(out)) {
  cat("\nmatched NPIs by taxonomy class:\n")
  print(count(filter(out, !is.na(npi)), npi_tax_class, sort = TRUE))
  cat(paste0(
    "  NOTE: a nursing-taxonomy NPI matching an AMCB name uniquely may still\n",
    "  be a different person who happens to be a nurse of that name. These are\n",
    "  a separate evidence stratum (matched_nursing_taxonomy), not primary.\n"))
}
cat("\nby resolution:\n"); print(count(filter(out, !is.na(npi)), npi_match_resolution, sort = TRUE))

# The categories that matter for identifiability, reported separately rather
# than rolled into a single yield number.
cat("\n---- identifiability breakdown ----\n")
ex <- filter(out, npi_match_method == "exact_last_first", !is.na(npi))
cat(sprintf("exact first+last, single candidate NPI : %s\n",
            format(sum(ex$n_candidates_pre_rank == 1), big.mark = ",")))
cat(sprintf("exact first+last, >1 candidate NPI     : %s\n",
            format(sum(ex$n_candidates_pre_rank > 1), big.mark = ",")))
cat(sprintf("resolved by middle name/initial        : %s\n",
            format(sum(out$npi_match_resolution == "resolved_by_middle", na.rm = TRUE),
                   big.mark = ",")))
cat(sprintf("fuzzy-surname matches                  : %s\n",
            format(sum(out$npi_match_method == "fuzzy_last_exact_first", na.rm = TRUE),
                   big.mark = ",")))
cat(sprintf("quarantined: tied on name evidence     : %s\n",
            format(sum(out$npi_match_status == "ambiguous_tied_names"), big.mark = ",")))
cat(sprintf("quarantined: contested NPI             : %s\n",
            format(sum(out$npi_match_status == "ambiguous_contested_npi"), big.mark = ",")))
cat(sprintf("unmatched (no candidate at all)        : %s\n",
            format(sum(out$npi_match_status == "unmatched"), big.mark = ",")))
dupe_names <- out %>% count(last_name, first_name) %>% filter(n > 1)
cat(sprintf("AMCB (last, first) names held by >1 row: %s names, %s rows\n",
            format(nrow(dupe_names), big.mark = ","),
            format(sum(dupe_names$n), big.mark = ",")))
cat(sprintf("NPIs contested by >1 AMCB row pre-bijection: %s\n",
            format(nrow(contested), big.mark = ",")))

cat("\nlinkage_tier (mutually exclusive):\n")
tiers <- out %>% count(linkage_tier) %>% mutate(pct = round(100 * n / nrow(out), 1))
print(as.data.frame(tiers))
stopifnot(sum(tiers$n) == nrow(out))
cat(sprintf("  primary_midwifery                  : %s (%.1f%%)\n",
            format(sum(out$linkage_tier == "primary_midwifery"), big.mark = ","),
            100 * mean(out$linkage_tier == "primary_midwifery")))
cat(sprintf("  + sensitivity_nursing increment    : %s (%+.1f pp)\n",
            format(sum(out$linkage_tier == "sensitivity_nursing"), big.mark = ","),
            100 * mean(out$linkage_tier == "sensitivity_nursing")))
cat(sprintf("  + sensitivity_fuzzy increment      : %s (%+.1f pp)\n",
            format(sum(out$linkage_tier == "sensitivity_fuzzy"), big.mark = ","),
            100 * mean(out$linkage_tier == "sensitivity_fuzzy")))
cat(sprintf("  quarantined                        : %s (%.1f%%), of which %s have candidates\n",
            format(sum(out$linkage_tier == "quarantined"), big.mark = ","),
            100 * mean(out$linkage_tier == "quarantined"),
            format(sum(out$linkage_tier == "quarantined" & out$has_candidate), big.mark = ",")))
cat(sprintf("  unmatched                          : %s (%.1f%%), of which %s HAVE candidates\n",
            format(sum(out$linkage_tier == "unmatched"), big.mark = ","),
            100 * mean(out$linkage_tier == "unmatched"),
            format(sum(out$linkage_tier == "unmatched" & out$has_candidate), big.mark = ",")))

cat("\nby confidence tier:\n")
print(out %>% filter(!is.na(npi)) %>%
        mutate(tier = cut(npi_match_confidence, c(-Inf, .5, .7, .85, Inf),
                          labels = c("<0.50", "0.50-0.70", "0.70-0.85", ">=0.85"))) %>%
        count(tier))
cat(sprintf("\ncity/state populated       : %s (%s)\n",
            format(sum(!is.na(out$nppes_state)), big.mark = ","),
            safe_pct(sum(!is.na(out$nppes_state)), n)))
cat("\nnppes_location_year distribution:\n")
print(count(filter(out, !is.na(nppes_location_year)), nppes_location_year))
dup <- out %>% filter(!is.na(npi)) %>% count(npi) %>% filter(n > 1)
cat(sprintf("\nduplicate NPI assignments  : %s\n", format(nrow(dup), big.mark = ",")))
cat(sprintf("saved artifact             : %s\n", normalizePath(OUT)))

cat("\n---------------- 20 matched rows ----------------\n")
print(out %>% filter(!is.na(npi)) %>%
        select(certification_number, status, last_name, first_name, npi,
               npi_match_method, npi_match_confidence, nppes_city, nppes_state,
               nppes_location_year) %>%
        slice_sample(n = min(20, nm)) %>% as.data.frame())
cat("\n------- 20 ambiguous / unmatched rows -------\n")
print(out %>% filter(is.na(npi)) %>%
        select(certification_number, status, last_name, first_name,
               middle_name, npi_match_status, n_candidates_pre_rank) %>%
        slice_sample(n = 20) %>% as.data.frame())
