#!/usr/bin/env Rscript
# =============================================================================
# AMCB certified midwives -> NPI, using the existing isochrones machinery
# =============================================================================
#
# This deliberately does NOT introduce another fuzzy matcher. It reuses
# matching-pipeline logic vendored from the isochrones repo (see "VENDORED,
# NOT SOURCED LIVE" below) rather than reimplementing it:
#
#   norm_name(), first_initial()   name normalisation (mysterynpi-backed)
#   rank_one_to_one()              greedy bijection with deterministic tiebreak
#   safe_pct()                     reporting helper
#
# compute_match_score() is NOT reused: this pipeline's own comment always
# said so (it collapses categorical identity evidence into one number, and
# this cohort has no location/DOB to make a finer scale mean anything --
# ordered evidence classes instead), so it is no longer required to exist.
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
  library(dplyr); library(readr); library(tibble); library(tidyr)
  library(digest); library(jsonlite)
})

root_dir <- {
  a <- grep("--file=", commandArgs(), value = TRUE)
  if (length(a)) normalizePath(dirname(sub("--file=", "", a[1]))) else normalizePath(".")
}

# --- VENDORED, NOT SOURCED LIVE (2026-10-22) ---------------------------------
# This used to setwd() into a private sibling repo (~/isochrones) and
# source() scripts/match_enthealth_to_npi.R live, picking up norm_name(),
# first_initial(), compute_match_score(), rank_one_to_one() and safe_pct()
# by side effect. That file was deleted upstream in an unrelated cleanup
# (isochrones commit 484d7405d, "remove the ENT side lane"), which is exactly
# the risk a live cross-repo source() always carries: this same mechanism had
# ALREADY caused three separate documented bugs here before it broke outright
# -- the accent-preserving norm_name (see below), a method_priority LUT
# mismatch, and an id_col default that silently changed underneath this
# pipeline. Vendoring the functions actually needed removes that whole
# failure class, at the cost of staying in sync by hand if upstream logic
# changes again.
#
# rank_one_to_one() below is copied verbatim from isochrones commit
# 56471c3f5^ (R/npi_resolution.R) -- the revision immediately BEFORE that
# repo's rank_one_to_one() was refactored to require mysterynpi >= 0.8.0
# (mysterynpi::resolve_one_to_one()). This project pins mysterynpi at
# ac42561b (see ci.yml / nightly.yml), which predates that function, so the
# current isochrones version cannot run here; this older, fully
# self-contained version can, and is what has actually been producing this
# pipeline's output. norm_name()/first_initial() now call mysterynpi
# directly rather than going through isochrones' own thin wrappers around
# the same package.
norm_name     <- function(x) mysterynpi::name_key(x)
first_initial <- function(x) mysterynpi::first_initial(x)
safe_pct <- function(n, d) {
  if (length(d) != 1L || is.na(d) || d == 0) return(0)
  if (length(n) != 1L) return(0)
  100 * n / d
}
rank_one_to_one <- function(candidates, id_col = "abog_id") {
  if (!is.character(id_col) || length(id_col) != 1L) {
    stop("rank_one_to_one: id_col must be a length-1 character string", call. = FALSE)
  }
  if (nrow(candidates) > 0 && !id_col %in% names(candidates)) {
    stop(sprintf("rank_one_to_one: id column '%s' not found in candidates.", id_col),
         call. = FALSE)
  }
  id <- rlang::sym(id_col)
  if (nrow(candidates) == 0) {
    return(candidates)
  }
  # BUG FIX (2026-02-16): is_ambiguous_op is created by Strategy 4 (Open Payments).
  # In TEST_MODE or when Strategy 4 has no matches, the column may not exist.
  # Default to FALSE (no ambiguous OP matches) when column is absent.
  if (!"is_ambiguous_op" %in% names(candidates)) {
    candidates$is_ambiguous_op <- FALSE
  }
  # HARDENING (2026-06-07, backported from canonical_abog_npi_pipeline_STABLE.R
  # commit e6056a22c): match_method may not exist in test data or when
  # strategies produce candidates without method labeling. Without this the
  # left_join below silently fails to create method_priority, surfacing as a
  # cryptic "object 'method_priority' not found" in the mutate(). Default to a
  # high priority value so these candidates rank low but don't crash.
  if (!"match_method" %in% names(candidates)) {
    candidates$match_method <- "unknown_method"
  }
  # If the caller already supplies method_priority there is nothing to look up.
  # This also lets the resolver be tested standalone, without loading a pipeline
  # that cannot source on its own (pre-existing is_truthy dependency).
  if ("method_priority" %in% names(candidates) &&
      !all(is.na(candidates$method_priority))) {
    method_lut <- NULL
  } else if (exists("build_method_priority_lut", mode = "function")) {
    method_lut <- build_method_priority_lut()
  } else {
    stop("rank_one_to_one: no method_priority column and build_method_priority_lut() is unavailable.",
         call. = FALSE)
  }
  # HARDENING: Row-count guard + warn on unknown match methods
  n_before_lut <- nrow(candidates)
  ranked <- if (is.null(method_lut)) candidates else candidates %>%
    dplyr::left_join(method_lut, by = "match_method", relationship = "many-to-one")
  if (nrow(ranked) != n_before_lut) {
    stop(sprintf(
      "[JOIN GUARD] method_lut join changed row count: %s -> %s (duplicate match_method keys?)",
      format(n_before_lut, big.mark = ","), format(nrow(ranked), big.mark = ",")
    ), call. = FALSE)
  }
  n_unknown_methods <- sum(is.na(ranked$method_priority))
  if (n_unknown_methods > 0) {
    unknown_methods <- unique(ranked$match_method[is.na(ranked$method_priority)])
    warning(sprintf(
      "[HARDENING] %s rows have unknown match_method (not in method_lut): %s\n  These will get priority=99, which is below every ordinary strategy but ABOVE the `unmatched` sentinel at 999 -- not the lowest, despite what this message used to say. Update build_method_priority_lut() if these are valid strategies.",
      format(n_unknown_methods, big.mark = ","),
      paste(head(unknown_methods, 5), collapse = ", ")
    ))
  }
  ranked <- ranked %>%
    dplyr::mutate(
      method_priority = dplyr::coalesce(method_priority, 99L),
      score_total = dplyr::coalesce(score_total, 0),
      confidence_score = dplyr::coalesce(confidence_score, 0),
      is_ambiguous_op = dplyr::coalesce(is_ambiguous_op, FALSE),
      score_total_adj = dplyr::if_else(
        is_ambiguous_op,
        score_total - 20L,
        score_total
      ),
      method_priority = dplyr::if_else(
        is_ambiguous_op,
        method_priority + 1L,
        method_priority
      )
    ) %>%
    dplyr::arrange(
      method_priority,
      dplyr::desc(score_total_adj),
      dplyr::desc(confidence_score),
      !!id
    )

  # PHASE A: resolve each roster person INDEPENDENTLY of any other person's
  # claim (a person is not "identified" merely because a rival candidate was
  # already consumed by someone else), using the three ranking keys as a
  # LEXICOGRAPHIC precedence order (best priority, then best score within
  # that, then best confidence within that -- not three independent filters).
  best <- ranked %>%
    dplyr::group_by(!!id) %>%
    dplyr::filter(method_priority == min(method_priority, na.rm = TRUE)) %>%
    dplyr::filter(score_total_adj == max(score_total_adj, na.rm = TRUE)) %>%
    dplyr::filter(confidence_score == max(confidence_score, na.rm = TRUE)) %>%
    dplyr::ungroup()
  best <- best %>% dplyr::distinct(!!id, npi, .keep_all = TRUE)

  tie_counts <- best %>%
    dplyr::distinct(!!id, npi) %>%
    dplyr::count(!!id, name = "n_best")
  best <- best %>% dplyr::left_join(tie_counts, by = id_col)
  tied <- best %>% dplyr::filter(n_best > 1L)
  provisional <- best %>% dplyr::filter(n_best == 1L)

  # PHASE B: enforce one NPI <-> one person, AFTER independent resolution.
  # NA is not a real NPI to contest -- excluded from the contest count so two
  # independently-unmatched people are never treated as fighting each other.
  contested_npis <- provisional %>%
    dplyr::filter(!is.na(npi)) %>%
    dplyr::distinct(!!id, npi) %>%
    dplyr::count(npi, name = "n_claimants") %>%
    dplyr::filter(n_claimants > 1L)
  contested <- provisional %>% dplyr::semi_join(contested_npis, by = "npi")
  resolved  <- provisional %>% dplyr::anti_join(contested_npis, by = "npi")

  quarantine <- dplyr::bind_rows(
    dplyr::mutate(tied, resolution_status = "ambiguous_tied_evidence"),
    dplyr::mutate(contested, resolution_status = "ambiguous_contested_npi")
  )
  out <- resolved %>%
    dplyr::mutate(resolution_status = "resolved") %>%
    dplyr::select(-dplyr::any_of("n_best")) %>%
    dplyr::arrange(!!id, npi)
  attr(out, "quarantine") <- quarantine %>%
    dplyr::select(-dplyr::any_of("n_best")) %>%
    dplyr::arrange(!!id, npi)
  attr(out, "n_ambiguous_tied_evidence") <- dplyr::n_distinct(tied[[id_col]])
  attr(out, "n_ambiguous_contested_npi") <- dplyr::n_distinct(contested[[id_col]])

  stopifnot(!any(duplicated(out[[id_col]])), !any(duplicated(out$npi)))
  out
}
for (fn in c("norm_name", "first_initial", "rank_one_to_one", "safe_pct")) {
  if (!exists(fn)) stop(sprintf("%s() not available", fn), call. = FALSE)
}
cat("reusing (vendored):", paste(c("rank_one_to_one", "safe_pct"), collapse = ", "), "\n")

# NAME NORMALISATION IS NOT TAKEN FROM THE ENT SCRIPT (2026-08-10).
#
# norm_name() and first_initial() are still defined above -- rank_one_to_one()
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
  base <- if (all(classes == "midwife")) "midwifery" else "midwifery-plus-nursing"
  # THE THIRD DIMENSION (2026-08-30). tax_class is midwife/nursing in BOTH the
  # narrow and the wide panel, so this returned the same string for a pool of
  # 443,623 NPIs and a pool of 845,255 -- and the auto-generated artifact name
  # was therefore identical for both. That is the defect this naming scheme
  # exists to prevent, recurring on a dimension it did not know about: the year
  # window was first, the taxonomy A/B second, taxonomy SCOPE is third.
  #
  # A panel built before tax_scope existed carries no such column, and its name
  # must not change -- the narrow artifact has to stay byte-reproducible. So an
  # absent column, and the value "narrow", both yield the historical name.
  if (!"tax_scope" %in% names(panel_df)) return(base)
  scope <- unique(panel_df$tax_scope[!is.na(panel_df$tax_scope) &
                                       nzchar(panel_df$tax_scope)])
  if (!length(scope)) return(base)
  if (length(scope) > 1L) {
    stop(sprintf("panel mixes taxonomy scopes (%s); one panel, one scope",
                 paste(sort(scope), collapse = ", ")), call. = FALSE)
  }
  if (identical(scope, "narrow")) base else paste0(base, "-", scope)
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
# mysterynpi::blank_na()/name_key() (0.3.1+) can fold a hyphen to a space via
# fold_hyphens = TRUE, added after discovering that 57 of 87 roster-wide
# sensitivity_fuzzy matches (66%) were PURELY a hyphen-vs-space SURNAME
# mismatch ("Abbas Rodriguez" vs "ABBAS-RODRIGUEZ"), not a genuine spelling
# difference. It defaults to FALSE and must be passed explicitly per call --
# a first attempt at defaulting it TRUE package-wide broke split_given(),
# turning a genuinely compound GIVEN name ("Samantha-Rose") into a given name
# plus a droppable middle token, producing cross-state false identity
# matches. last_clean/nppes_last_clean below pass it explicitly; nothing
# touching a given or middle name may. See mysterynpi's own name_key() and
# split_given() docstrings for the full defect writeup.
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
         # fold_hyphens = TRUE ONLY here (a SURNAME comparison). Never on a
         # given-name field -- see mysterynpi::split_given()'s own warning
         # and regression test for the cross-state false-match defect that
         # produced when this was briefly the package-wide default.
         last_clean  = blank_na(last_name, fold_hyphens = TRUE),
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
  mutate(nppes_last_clean  = blank_na(last_name, fold_hyphens = TRUE),
         nppes_first_clean = blank_na(first_name),
         nppes_first_init  = coalesce(amcb_first_initial(nppes_first_clean), ""),
         nppes_mid_init    = substr(blank_na(middle_name), 1, 1),
         # The WHOLE middle name, not just its first letter. The middle-name
         # axis compares token sets (amcb_middle_agreement); an initial cannot
         # represent "ANN MARIE" or "REINHARD" for that comparison.
         nppes_middle_clean = blank_na(middle_name),
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
  distinct(npi, nppes_last_clean, nppes_first_clean, nppes_first_init,
           nppes_mid_init, nppes_middle_clean) %>%
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

# --- Strategy 3 (fuzzy surname, evidence class 4) RETIRED (2026-10-22) ------
# This strategy joined on exact given name and accepted any surname within
# Levenshtein distance <= 2 (stringdist(last_clean, nppes_last_clean,
# method = "lv")) as a candidate:
#
#   s3 <- amcb_named %>%
#     inner_join(identities, by = c("first_clean" = "nppes_first_clean"), ...) %>%
#     mutate(lv_last = stringdist(last_clean, nppes_last_clean, method = "lv")) %>%
#     filter(lv_last > 0, lv_last <= 2, nchar(last_clean) >= 5) %>%
#     ...
#
# Removed by decision: edit-distance similarity is too easy to satisfy for a
# reason that has nothing to do with shared identity -- two different real
# people whose surnames happen to differ by one or two characters got the
# same name evidence as someone whose surname is a deliberately recorded
# variant. The strategy-5 component match below is kept: it is NOT a
# distance metric, it requires an exact token match on one half of a
# compound surname, a different and more auditable kind of partial evidence.
# Evidence class 4 is retired along with it, not reassigned -- see the
# evidence-class comment block below bind_rows().

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
#   5  surname component + exact first (WEAKEST -- see strategy 5 above)
#
# Class 4 (fuzzy/Levenshtein surname match) is retired (2026-10-22, see
# strategy 3's removal above) -- the number is not reused, so "4" never means
# something different than it used to in any historical export. Resolution
# still takes min(class) as the strongest evidence; a partial surname (5)
# must never outrank a whole one.
candidates_prefilter <- bind_rows(s1, s2, s5) %>%
  mutate(
    component_last = coalesce(component_last, 0L),
    # TOKEN SETS, NOT POSITION 1. See amcb_middle_agreement() in
    # R/amcb_match_rules.R for the defect this replaces and for what it
    # deliberately still treats as a conflict. mid_both is retained because
    # downstream code and the gates read it as "both sides recorded a middle
    # name", which is exactly the uninformative/other split below.
    mid_agreement = amcb_middle_agreement(amcb_middle_tokens(middle_clean),
                                          amcb_middle_tokens(nppes_middle_clean)),
    mid_both   = mid_agreement != "uninformative",
    mid_match  = as.integer(mid_agreement == "corroborates"),
    mid_conflict = as.integer(mid_agreement == "conflicts"),
    name_evidence_class = case_when(
      exact_last == 1L & exact_first == 1L & mid_match == 1L ~ 1L,
      exact_last == 1L & exact_first == 1L                   ~ 2L,
      exact_last == 1L & first_init_ok == 1L                 ~ 3L,
      component_last == 1L                                   ~ 5L),
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

# THE SAME QUESTION AT THE TOP OF THE SCALE (2026-08-30).
#
# "Ruled in, or merely not ruled out?" was asked of class 5 and answered by
# quarantining. It was never asked of class 2, where the veto is strongest --
# it removes a candidate agreeing on BOTH whole names -- and where it runs in
# two directions at once. Audited over the frozen linkage, of 2,240 roster rows
# with at least one exact-name candidate vetoed:
#
#   1,454  ruled IN by a middle name that agrees on another candidate; the
#          veto changes nothing for them
#     218  resolve at class 2 ONLY because every rival was vetoed -- the class-5
#          pattern exactly, unflagged, 120 of them cohort members
#     568  unresolved either way, including 82 whose ONLY exact-name candidate
#          was deleted and who are then published as "no candidate"
#
# Both tails are now counted. Nothing is demoted: unlike class 5, the surviving
# claim here rests on agreement of the whole given name AND the whole surname,
# which is not thin evidence, and moving cohort membership on a rule this
# script has never reported would be a change made blind. The columns make the
# stratum reportable; whether it should move is a separate, evidenced decision.
vetoed_exact_pairs <- candidates_prefilter %>%
  filter(exact_last == 1L, exact_first == 1L, mid_conflict == 1L) %>%
  distinct(amcb_id, vetoed_npi = npi)
cat(sprintf("middle-veto footprint: %s class-5 pairs, %s exact-name pairs\n",
            format(nrow(vetoed_c5_pairs), big.mark = ","),
            format(nrow(vetoed_exact_pairs), big.mark = ",")))

cat("\ncandidates by name_evidence_class x taxonomy:\n")
print(as.data.frame(count(candidates, name_evidence_class, taxonomy_axis)))

# Full candidate audit table: every plausible pair survives here even when it
# loses, so adding a candidate source can never make a known candidate vanish.
# first_year / last_year were declared here and left NA from the beginning. They
# are the only axis in this data that name rules cannot see, and leaving them
# empty is why no one could say whether a temporal comparison would separate any
# of the 3,044 tied records -- the question could not even be asked from a
# committed artifact. They are populated from the panel now.
#
# THEY ARE BOUNDS, NOT DATES. The panel begins at PANEL_FLOOR and NPPES began
# enumerating in 2006, so an NPI first seen in the earliest snapshot may have
# enumerated before it. first_year_censored says so per row rather than leaving
# a reader to infer it, following the convention in build_reassignment_panel.R.
npi_years <- panel %>%
  filter(!is.na(snapshot_year)) %>%
  group_by(npi) %>%
  summarise(first_year = min(snapshot_year), last_year = max(snapshot_year),
            .groups = "drop") %>%
  mutate(first_year_censored = first_year == min(first_year, na.rm = TRUE))

cand_audit <- candidates %>%
  transmute(amcb_id, npi, name_evidence_class, taxonomy_axis, match_method,
            exact_last, exact_first, first_init_ok, mid_match, lv_last) %>%
  left_join(npi_years, by = "npi")
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

CONTESTED_RULE <- Sys.getenv("CONTESTED_RULE", "strict_dominance")
ranked <- resolved %>%
  # rank_one_to_one() ranks on method_priority, score_total then
  # confidence_score. Feed it the evidence class as the score so the bijection
  # prefers the strongest identity evidence, not an arbitrary row order.
  mutate(enthealth_id = amcb_id,
         score_total = 5L - name_evidence_class,
         match_strategy = name_evidence_class,
         # method_priority SUPPLIED, NOT LOOKED UP (2026-08-30). rank_one_to_one()
         # otherwise joins build_method_priority_lut(), which is keyed on the ABOG
         # pipeline's strategy names ("strategy1_exact_npi", ...) and contains NONE
         # of this pipeline's four methods. Every midwifery row therefore missed
         # the lookup and was coalesced to the same value, 99 -- so the bijection
         # has ALWAYS ranked on score_total, exactly as the note below says. The
         # constant is reproduced here rather than re-derived, so this run ranks
         # identically to the frozen one; what changes is that the pipeline no
         # longer depends on a table that never applied to it, and the LUT now
         # lives where it is used instead of being loaded by side effect.
         method_priority = 99L) %>%
  # id_col PASSED, NOT DEFAULTED (2026-08-30). rank_one_to_one() is canonical
  # and lives in another repository; consolidating its four copies moved the
  # default from "enthealth_id" to "abog_id", and this script -- which had
  # relied on the default -- stopped running entirely:
  #
  #   Error: rank_one_to_one: id column 'abog_id' not found in candidates.
  #
  # Loud, and therefore survivable. The dangerous version of this is a repo
  # that HAS a column by the new default name: the bijection would then be
  # enforced over the wrong identifier and the run would look clean. Naming the
  # column here makes this pipeline's contract independent of that default.
  rank_one_to_one(id_col = "enthealth_id")

# CONTESTED NPIs ARE NOT ALL THE SAME KIND OF CONTESTED (2026-08-30).
# rank_one_to_one() now quarantines BOTH claimants of a contested NPI. That
# withdrew 93 people from this cohort, but only 37 of those 93 are genuinely
# inseparable; for the other 56 one claimant holds strictly stronger name
# evidence. amcb_award_contested() returns those and leaves the coin-flips
# quarantined. Measured on THIS pipeline, where the middle-name fix has already
# shrunk the contested set: 53 awarded, 123 rows still contested. See
# R/amcb_match_rules.R for the three rules and their measured costs, and
# docs/TECHNICAL_APPENDIX_CONTESTED_NPI.md.
awarded <- amcb_award_contested(attr(ranked, "quarantine"),
                                rule = CONTESTED_RULE)
cat(sprintf("contested rule: %s -- %s NPI(s) awarded on strictly stronger evidence\n",
            CONTESTED_RULE, format(nrow(awarded), big.mark = ",")))
matched <- dplyr::bind_rows(ranked, awarded) %>%
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
matched_one_row <- as.data.frame(matched %>% select(amcb_id, npi))
mid_veto_stats <- count_rival_npis(
  as.data.frame(vetoed_c5_pairs), matched_one_row) %>%
  rename(n_mid_vetoed_c5 = n_rival_npis)

# Same rival rule, same self-variant guard, applied to the exact-name tier. A
# row that matched nothing has no NPI to exclude, so every deleted candidate
# counts -- which is precisely the count that was missing from the "unmatched"
# stratum.
mid_veto_stats_c2 <- count_rival_npis(
  as.data.frame(vetoed_exact_pairs), matched_one_row) %>%
  rename(n_mid_vetoed_c2 = n_rival_npis)

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
  left_join(mid_veto_stats_c2, by = "amcb_id") %>%
  mutate(n_mid_vetoed_c5 = coalesce(n_mid_vetoed_c5, 0L),
         n_mid_vetoed_c2 = coalesce(n_mid_vetoed_c2, 0L),
         # Ruled in, or merely not ruled out. TRUE when a class-5 match
         # survived ONLY because it carried no middle initial to conflict,
         # while recorded alternatives were vetoed by theirs.
         resolved_by_absence_c5 = !is.na(npi) & name_evidence_class == 5L &
           n_mid_vetoed_c5 > 0L & !has_name_information(nppes_mid_init),
         # The class-2 twin. TRUE when a match on the whole given name and the
         # whole surname is UNIQUE only because every rival carrying those same
         # two names was removed on its middle name. The claim is stronger than
         # the class-5 case -- two whole names, not a surname fragment -- but it
         # is the same kind of claim, and it was previously unreportable.
         # Deliberately NOT demoted: see vetoed_exact_pairs above.
         resolved_by_absence_c2 = !is.na(npi) & name_evidence_class == 2L &
           n_mid_vetoed_c2 > 0L & !has_name_information(nppes_mid_init)) %>%
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
    !is.na(npi) & normalise_npi_tax_class(npi_tax_class) == "nursing" ~
      "matched_nursing_taxonomy",
    !is.na(npi) & is.na(normalise_npi_tax_class(npi_tax_class)) ~
      "matched_unknown_taxonomy",
    !is.na(npi)                  ~ "matched",
    amcb_id %in% quarantined_ids ~ "ambiguous_tied_names",
    amcb_id %in% lost_bijection  ~ "ambiguous_contested_npi",
    TRUE                         ~ "unmatched")) %>%
  mutate(across(c(n_candidates_pre_rank, n_midwifery_candidates,
                  n_nursing_only_candidates), ~ coalesce(.x, 0L))) %>%
  # "no plausible NPI exists" and "plausible NPIs exist but identity is
  # ambiguous" are different kinds of missingness and must stay separable.
  mutate(has_candidate = n_candidates_pre_rank > 0,
         # THE OTHER TAIL. has_candidate is computed AFTER the middle veto, so
         # a row whose only exact-name candidate was deleted reads FALSE --
         # identical to a person who is genuinely not in the registry. These
         # are different failures and the difference was not recorded anywhere.
         # This does not restore the candidate or change the status; it makes
         # the stratum countable, which is what "no candidate at all" was
         # asserting without evidence.
         unmatched_after_middle_veto = npi_match_status == "unmatched" &
           n_mid_vetoed_c2 > 0L,
         linkage_tier = amcb_linkage_tier(
           npi, name_evidence_class, npi_tax_class,
           demoted_absence_c5 = npi_demoted_absence_c5,
           match_status = npi_match_status),
         # candidate_count is the pool BEFORE resolution -- how many NPIs were
         # ever plausible for this person. Reporting the post-bijection count
         # would always be 0 or 1 and would hide every ambiguity.
         candidate_count = n_candidates_pre_rank,
         # TRUE when the spelling that produced the match is not the spelling
         # NPPES currently reports for that NPI. Without this a reviewer reads
         # a legitimate name change as a false match; with it, the row explains
         # itself. Compared on the normalised key, not the raw string, so an
         # accent alone can never raise the flag. Both sides are surnames, so
         # fold_hyphens = TRUE here too -- a punctuation-only change
         # ("SMITH-JONES" -> "SMITH JONES") is not a real name change.
         nppes_name_changed_since_match = !is.na(npi) &
           !is.na(nppes_matched_last) & !is.na(nppes_last_name) &
           blank_na(nppes_matched_last, fold_hyphens = TRUE) !=
             blank_na(nppes_last_name, fold_hyphens = TRUE),
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
           unmatched_after_middle_veto ~ "exact_name_candidates_removed_on_middle_name",
           TRUE                                          ~ "none"),
         # A sentence a human can check, built from the evidence actually used.
         match_reason = case_when(
           # Said "no candidate shared this name" over rows that HAD one and
           # lost it to the middle-name veto. The sentence is the artifact's
           # human-readable evidence column; it has to be true.
           is.na(npi) & !has_candidate & unmatched_after_middle_veto ~
             sprintf(paste("%d NPPES candidate(s) shared the whole given name",
                           "and surname; all removed on middle-name conflict"),
                     n_mid_vetoed_c2),
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
                                      "sensitivity_unknown_taxonomy",
                                      "quarantined", "unmatched")),
          sum(table(out$linkage_tier)) == nrow(amcb),
          !any(out$linkage_tier == "primary_midwifery" &
                 normalise_npi_tax_class(out$npi_tax_class) != "midwife", na.rm = TRUE))
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
