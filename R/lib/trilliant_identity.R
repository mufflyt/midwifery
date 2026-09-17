# =============================================================================
# Trilliant's provider directory as a second identity source for AMCB -> NPI
# =============================================================================
# The linkage (match_amcb_to_npi.R) resolves an AMCB certificant to an NPI on
# name evidence alone, because AMCB publishes a name, a credential and dates
# and nothing else. Trilliant's directory (snapshot 2026-06-25) is a second,
# independently assembled record for 7.5 million individual NPIs. For a
# candidate NPI it can say three things the name cannot:
#
#   profession  a midwifery, nursing, physician or other specialty and
#               credential (and, through NPPES, every taxonomy the NPI holds);
#   graduation  the CMS DAC graduation year, which for a certified nurse-midwife
#               is within one year of the AMCB certification year for 89.6% of
#               primary-tier links (measured on the 2026-08-10 freeze);
#   sex         weak only: AMCB publishes no sex, and 99% of the cohort is
#               female, so MALE is a mild penalty and nothing more.
#
# Everything here builds EVIDENCE about (certificant, candidate NPI) pairs. It
# never writes a link. The experiment that uses it
# (experiment_trilliant_identity_linkage.R) writes proposals beside the frozen
# linkage and changes nothing in it.
#
# WHAT IS DELIBERATELY NOT EVIDENCE
#   active_provider, the patient panel, practice count and practice location
#       come from claims. Trilliant attributes a clinician to any organisation
#       whose claim carries their NPI in an ordering or referring role (a lab
#       the midwife sends specimens to), so these describe activity, not
#       identity. They are carried as context and never scored.
#   provider_estimated_age is graduation year minus a constant (see
#       R/lib/trilliant_demographics.R); scoring it would count graduation
#       year twice.
#   school, state and organisation have nothing on the AMCB side to agree
#       with: AMCB publishes no location, employer or school. They can compare
#       two NPIs with each other, which says nothing about which one is the
#       certificant, so they are context only.
#
# TWO VARIANTS, BECAUSE THE REPOSITORY HAS AN OPEN RULING
#   The resolver refuses to let taxonomy break a tie (R/amcb_resolver.R;
#   DECISIONS_CONTRACT.md D17, "RULING: none"): taxonomy says what an NPI does
#   for a living, not which person a name refers to. So every pair is scored
#   twice. `full` scores profession as the experiment's brief asks;
#   `identity_only` gives profession no points and keeps it only as a filter
#   (a physician or other non-nursing record is contradicted in both), which
#   is the resolver's own stance. Both are reported; neither is applied.
#
# Weights and thresholds were fixed before any stratum's outcome was looked at,
# from two prior measurements: the graduation-year distribution above, and the
# frozen matcher's evidence classes. They are points, not probabilities; no
# score here is calibrated against adjudicated truth (the v1 truth set is
# sealed until adjudication completes and must not be consulted). ONE CHANGE
# WAS MADE AFTER LOOKING (2026-09-14): the first run counted fused, split and
# one-edit given names as contradictions of correct links, so three given-name
# levels were added (trl_name_evidence()). No weight was retuned. The first
# run also measured that a graduation year two or three years off is evidence
# AGAINST a link (likelihood ratio about 0.3), not the +1.5 set here; that is
# reported in the appendix and deliberately NOT corrected, so this run stays
# the pre-specified one.
#
# Pure functions: no I/O. Callers source credential_compatibility.R first
# (classify_credentials()); name comparisons are mysterynpi's canonical ones.
# =============================================================================

suppressPackageStartupMessages({
  library(dplyr)
})

#' NUCC taxonomy codes that are midwifery (nurse-midwife, midwife, lay midwife)
TRL_MIDWIFE_TAXONOMY <- c("367A00000X", "176B00000X", "175M00000X")

#' Nursing taxonomy families: registered nurse, nurse practitioner, clinical
#' nurse specialist, nurse anesthetist. 367H (anesthesiologist assistant) is
#' not nursing, which is why this is 3675 and not 367.
TRL_NURSING_TAXONOMY_PREFIX <- c("163W", "363L", "364S", "3675")

#' Points per evidence level. Fixed in advance; see the header.
TRL_IDENTITY_WEIGHTS <- list(
  surname    = c(exact = 4, component = 3, alias_nppes = 3, edit_1_2 = 2, different = 0),
  given      = c(exact = 3, compound = 3, nickname = 2, spelling_variant = 2, given_in_middle = 1.5,
                 initial = 1, conflict = 0),
  middle     = c(corroborates = 2, initial_only = 1, uninformative = 0, conflicts = -2),
  profession = c(midwife = 5, nursing = 1, unknown = 0, physician = -5, other = -5),
  grad_year  = c(within_1 = 3, within_3 = 1.5, within_10 = 0, beyond_10 = -3, unknown = 0),
  sex        = c(male = -1, not_male = 0))

#' Decision thresholds per scoring variant.
#'   plausible  the least a contradiction-free candidate needs to be worth
#'              reviewing (full: an exact name plus nursing plus something)
#'   accept     the least an unopposed candidate needs to be proposed
#'   margin     how far the best candidate must lead the runner-up
TRL_DECISION_RULES <- list(
  full          = list(plausible = 9, accept = 12, margin = 4),
  identity_only = list(plausible = 7, accept = 10, margin = 3))

#' NA to "", as character: the form every key and comparison here expects.
#' @param x vector
#' @return character, no NA.
trl_blank <- function(x) { x <- as.character(x); x[is.na(x)] <- ""; x }

#' Classify a NUCC taxonomy code
#' @param code [character]
#' @return "midwife", "nursing", "physician", "other", or NA when absent.
trl_taxonomy_class <- function(code) {
  code <- toupper(trimws(as.character(code)))
  dplyr::case_when(
    is.na(code) | !nzchar(code) ~ NA_character_,
    code %in% TRL_MIDWIFE_TAXONOMY ~ "midwife",
    substr(code, 1, 4) %in% TRL_NURSING_TAXONOMY_PREFIX ~ "nursing",
    substr(code, 1, 2) == "20" ~ "physician",
    TRUE ~ "other")
}

#' Credential text to the same four classes
#'
#' Delegates to classify_credentials() (credential_compatibility.R), the
#' repository's midwifery-aware credential rule, and renames its labels.
#' @param credential [character]
#' @return "midwife", "nursing", "physician", "other", or NA.
trl_credential_class <- function(credential) {
  if (!exists("classify_credentials", mode = "function"))
    stop("source credential_compatibility.R before R/lib/trilliant_identity.R's callers", call. = FALSE)
  k <- classify_credentials(credential)
  unname(c(midwifery = "midwife", nursing = "nursing", physician = "physician",
           other_doc = "other", UNKNOWN = NA_character_)[k])
}

#' One profession per candidate, from every source that speaks
#'
#' Midwifery from ANY source wins, then nursing, then physician, then other:
#' an OB/GYN taxonomy on a record credentialed "CNM" is a midwife with a
#' mis-filed taxonomy far more often than a physician with a stray credential,
#' and `profession_mixed` flags it for the reader either way.
#' @param specialty_class,credential_class [character] from the two functions above.
#' @param nppes_classes [character] "|"-joined classes of every NPPES taxonomy the NPI holds.
#' @return tibble: profession_class, profession_mixed.
trl_profession <- function(specialty_class, credential_class, nppes_classes = NA_character_) {
  n <- length(specialty_class)
  nppes_classes <- rep_len(as.character(nppes_classes), n)
  has <- function(cls) {
    (!is.na(specialty_class) & specialty_class == cls) |
      (!is.na(credential_class) & credential_class == cls) |
      (!is.na(nppes_classes) & grepl(paste0("(^|\\|)", cls, "(\\||$)"), nppes_classes))
  }
  mid <- has("midwife"); nur <- has("nursing"); phy <- has("physician"); oth <- has("other")
  tibble::tibble(
    profession_class = ifelse(mid, "midwife", ifelse(nur, "nursing", ifelse(phy, "physician",
                         ifelse(oth, "other", "unknown")))),
    profession_mixed = (mid | nur) & (phy | oth))
}

#' Graduation year against certification year
#'
#' d = graduation year - certification year. Bands come from the measured
#' distribution among primary-tier links on the 2026-08-10 freeze (1st
#' percentile -11, 99th +13): beyond ten years either way is rare for a true
#' link and is counted as a contradiction.
#' @param grad_year,cert_year [integer]
#' @return band label, "unknown" when either year is missing.
trl_grad_year_band <- function(grad_year, cert_year) {
  d <- suppressWarnings(as.integer(grad_year) - as.integer(cert_year))
  dplyr::case_when(is.na(d) ~ "unknown",
                   abs(d) <= 1L ~ "within_1",
                   abs(d) <= 3L ~ "within_3",
                   abs(d) <= 10L ~ "within_10",
                   TRUE ~ "beyond_10")
}

#' Name evidence for (certificant, candidate) pairs
#'
#' Every comparison is mysterynpi's: surname_agreement() (whole key, a shared
#' surname token, or a surname carried as the other side's middle name, the
#' usual shape of a maiden name), middle_agreement(), nickname_agreement().
#' Rules are added, each stated where it applies:
#'   - a middle name mysterynpi calls a conflict but whose first letters agree
#'     (ANN / ANNE) is `initial_only`, not a contradiction. The frozen matcher's
#'     class 1 is a middle-INITIAL rule, and a spelling variant of one middle
#'     name is not evidence of two people.
#'   - `alias_nppes`: the certificant's surname is one NPPES records as the
#'     candidate's "other last name". Checked after the direct rules, so an
#'     alias never outranks the name the NPI carries now.
#'   - three given-name levels found by inspecting the first run, where each
#'     had been counted as a contradiction of a correct link (2026-09-14):
#'       `compound`         one given name fused or split differently:
#'                          ROSEANNE / Rose Anne, ANNA-MARIA / Anna Maria,
#'                          MARYJO / Mary (one a prefix of the other, >= 3 letters)
#'       `spelling_variant` one edit apart, both at least six letters:
#'                          KATHRYN / KATHRIN, JOHANNA / JOHANA. Shorter
#'                          names are excluded because KERRY / TERRY are two names.
#'       `given_in_middle`  one side's given name is among the other side's
#'                          middle names: a person who goes by a middle or
#'                          English name (MEILING / Grace Meiling)
#'     None of them is a contradiction; each scores below an exact given name.
#'
#' @param pairs data frame with, per pair: amcb_last, amcb_given, amcb_middle,
#'   trl_last, trl_given, trl_middle (normalised keys, "" when absent),
#'   nppes_other_last ("" when none), last_edit_distance (integer; NA allowed).
#' @return `pairs` with surname_evidence, given_evidence, middle_evidence.
trl_name_evidence <- function(pairs) {
  need <- c("amcb_last", "amcb_given", "amcb_middle", "trl_last", "trl_given",
            "trl_middle", "nppes_other_last", "last_edit_distance")
  miss <- setdiff(need, names(pairs))
  if (length(miss)) stop("trl_name_evidence: missing column(s) ", paste(miss, collapse = ", "), call. = FALSE)
  if (!nrow(pairs)) return(dplyr::mutate(pairs, surname_evidence = character(0),
                                         given_evidence = character(0), middle_evidence = character(0)))
  blank <- function(x) { x <- as.character(x); x[is.na(x)] <- ""; x }
  p <- pairs
  for (v in setdiff(need, "last_edit_distance")) p[[v]] <- blank(p[[v]])

  # Comparators are per-row loops; run them once per distinct combination.
  u <- dplyr::distinct(p, amcb_last, trl_last, amcb_middle, trl_middle, nppes_other_last)
  direct <- mysterynpi::surname_agreement(u$amcb_last, u$trl_last,
                                          middle_a = u$amcb_middle, middle_b = u$trl_middle)
  alias <- mysterynpi::surname_agreement(u$amcb_last, u$trl_last,
                                         alternates_b = as.list(u$nppes_other_last))
  u$surname_rule <- ifelse(u$amcb_last == u$trl_last & nzchar(u$amcb_last), "exact",
                    ifelse(direct == "corroborates", "component",
                    ifelse(alias == "corroborates" & nzchar(u$nppes_other_last), "alias_nppes", "none")))
  p <- dplyr::left_join(p, u, by = c("amcb_last", "trl_last", "amcb_middle", "trl_middle", "nppes_other_last"),
                        relationship = "many-to-one")
  p$surname_evidence <- ifelse(p$surname_rule != "none", p$surname_rule,
                        ifelse(!is.na(p$last_edit_distance) & p$last_edit_distance <= 2L, "edit_1_2", "different"))
  p$surname_rule <- NULL

  g <- dplyr::distinct(p, amcb_given, trl_given, amcb_middle, trl_middle)
  squash <- function(x) gsub("[^A-Z]", "", toupper(x))
  first_tok <- function(x) vapply(strsplit(x, " ", fixed = TRUE), function(t) if (length(t)) t[1] else "", "")
  in_tokens <- function(word, phrase) mapply(function(w, s) nzchar(w) && w %in% strsplit(s, " ", fixed = TRUE)[[1]],
                                             word, phrase, USE.NAMES = FALSE)
  ga <- squash(g$amcb_given); gt <- squash(g$trl_given)
  prefix <- nchar(ga) >= 3L & nchar(gt) >= 3L & (startsWith(ga, gt) | startsWith(gt, ga))
  fused <- (nzchar(ga) & ga == squash(paste0(g$trl_given, first_tok(g$trl_middle)))) |
    (nzchar(gt) & gt == squash(paste0(g$amcb_given, first_tok(g$amcb_middle))))
  lv1 <- nchar(ga) >= 6L & nchar(gt) >= 6L &
    mapply(function(a, b) utils::adist(a, b)[1, 1] <= 1L, ga, gt, USE.NAMES = FALSE)
  in_mid <- in_tokens(g$amcb_given, g$trl_middle) | in_tokens(g$trl_given, g$amcb_middle)
  nick <- mysterynpi::nickname_agreement(g$amcb_given, g$trl_given)
  one_letter <- nchar(g$amcb_given) == 1L | nchar(g$trl_given) == 1L
  g$given_evidence <- dplyr::case_when(
    g$amcb_given == g$trl_given & nzchar(g$amcb_given) ~ "exact",
    nick == "corroborates" & one_letter ~ "initial",
    fused | prefix ~ "compound",
    nick == "corroborates" ~ "nickname",
    lv1 ~ "spelling_variant",
    in_mid ~ "given_in_middle",
    TRUE ~ "conflict")
  p <- dplyr::left_join(p, g, by = c("amcb_given", "trl_given", "amcb_middle", "trl_middle"),
                        relationship = "many-to-one")

  m <- dplyr::distinct(p, amcb_middle, trl_middle)
  ag <- mysterynpi::middle_agreement(mysterynpi::middle_tokens(m$amcb_middle),
                                     mysterynpi::middle_tokens(m$trl_middle))
  same_initial <- nzchar(m$amcb_middle) & nzchar(m$trl_middle) &
    substr(m$amcb_middle, 1, 1) == substr(m$trl_middle, 1, 1)
  m$middle_evidence <- ifelse(ag == "conflicts" & same_initial, "initial_only", ag)
  dplyr::left_join(p, m, by = c("amcb_middle", "trl_middle"), relationship = "many-to-one")
}

#' Score pairs under both variants and count contradictions
#'
#' @param ev data frame with surname_evidence, given_evidence, middle_evidence,
#'   profession_class, grad_year_band, trl_sex ("F", "M" or NA).
#' @param weights see TRL_IDENTITY_WEIGHTS.
#' @return `ev` plus the per-field points, contradiction flags,
#'   contradiction_count, corroborated_full / corroborated_identity (a
#'   non-name field supports the pair), score_full and score_identity_only.
trl_score_pairs <- function(ev, weights = TRL_IDENTITY_WEIGHTS) {
  need <- c("surname_evidence", "given_evidence", "middle_evidence", "profession_class",
            "grad_year_band", "trl_sex")
  miss <- setdiff(need, names(ev))
  if (length(miss)) stop("trl_score_pairs: missing column(s) ", paste(miss, collapse = ", "), call. = FALSE)
  pts <- function(field, level) {
    w <- weights[[field]]
    bad <- setdiff(unique(level), names(w))
    if (length(bad)) stop("unknown ", field, " level(s): ", paste(bad, collapse = ", "), call. = FALSE)
    unname(w[level])
  }
  sex_level <- ifelse(!is.na(ev$trl_sex) & ev$trl_sex == "M", "male", "not_male")
  ev |>
    dplyr::mutate(
      pts_surname = pts("surname", surname_evidence),
      pts_given = pts("given", given_evidence),
      pts_middle = pts("middle", middle_evidence),
      pts_profession = pts("profession", profession_class),
      pts_grad_year = pts("grad_year", grad_year_band),
      pts_sex = pts("sex", sex_level),
      contra_given = given_evidence == "conflict",
      contra_middle = middle_evidence == "conflicts",
      contra_profession = profession_class %in% c("physician", "other"),
      contra_grad_year = grad_year_band == "beyond_10",
      contradiction_count = as.integer(contra_given) + as.integer(contra_middle) +
        as.integer(contra_profession) + as.integer(contra_grad_year),
      corroborated_identity = grad_year_band %in% c("within_1", "within_3"),
      corroborated_full = corroborated_identity | profession_class == "midwife",
      score_identity_only = pts_surname + pts_given + pts_middle + pts_grad_year + pts_sex,
      score_full = score_identity_only + pts_profession)
}

#' Rank each certificant's candidates
#'
#' Ties share a rank (`min`), so a tie at the top is visible as n_at_top > 1
#' rather than broken by row order.
#' @param scored output of trl_score_pairs(); needs amcb_id, npi.
#' @param variant "full" or "identity_only".
#' @return one row per pair plus rank, n_at_top, top_score, runner_up_score
#'   (NA when there is no second candidate) and margin (top minus runner-up;
#'   NA when unopposed).
trl_rank_candidates <- function(scored, variant = c("full", "identity_only")) {
  variant <- match.arg(variant)
  sc <- paste0("score_", variant)
  scored |>
    dplyr::mutate(.score = .data[[sc]]) |>
    dplyr::group_by(amcb_id) |>
    dplyr::mutate(
      rank = dplyr::min_rank(dplyr::desc(.score)),
      n_at_top = sum(rank == 1L),
      top_score = max(.score),
      runner_up_score = {
        s <- sort(.score, decreasing = TRUE)
        if (length(s) > 1L) s[2] else NA_real_
      },
      margin = top_score - runner_up_score) |>
    dplyr::ungroup() |>
    dplyr::select(-.score)
}

#' One decision per certificant from its ranked candidates
#'
#' ACCEPT (a proposal, never applied) needs every one of: a single best
#' candidate; no contradiction on it; at least the accept score; a lead of at
#' least the margin over the runner-up (unopposed counts as a lead); a
#' non-name field in support; surname evidence of some kind (a candidate whose
#' surname differs with nothing to explain it is at most REVIEW, however well
#' the rest agrees); and an NPI no other certificant already holds. REVIEW is
#' a plausible best candidate that misses any of those. UNRESOLVED is no
#' plausible candidate, and `emptied` says whether candidates existed and every
#' one was contradicted -- DECISIONS_CONTRACT D17 requires emptied pools to be
#' reported apart from separations.
#'
#' @param ranked output of trl_rank_candidates() for one variant; needs amcb_id,
#'   npi, and npi_held_by_other_certificant (logical).
#' @param variant "full" or "identity_only".
#' @param rules see TRL_DECISION_RULES.
#' @return one row per amcb_id: decision, decision_reason, best_npi,
#'   best_score, runner_up_score, margin, n_candidates, emptied.
trl_decide <- function(ranked, variant = c("full", "identity_only"), rules = TRL_DECISION_RULES) {
  variant <- match.arg(variant)
  r <- rules[[variant]]
  sc <- paste0("score_", variant)
  corr <- if (variant == "full") "corroborated_full" else "corroborated_identity"
  best <- ranked |>
    dplyr::group_by(amcb_id) |>
    dplyr::mutate(n_candidates = dplyr::n(),
                  n_contradiction_free = sum(contradiction_count == 0L)) |>
    dplyr::filter(rank == 1L) |>
    dplyr::arrange(npi, .by_group = TRUE) |>
    dplyr::summarise(
      n_candidates = dplyr::first(n_candidates),
      n_contradiction_free = dplyr::first(n_contradiction_free),
      n_at_top = dplyr::first(n_at_top),
      best_npi = if (dplyr::n() == 1L) dplyr::first(npi) else NA_character_,
      tied_npis = if (dplyr::n() > 1L) paste(npi, collapse = "|") else NA_character_,
      best_score = dplyr::first(.data[[sc]]),
      runner_up_score = dplyr::first(runner_up_score),
      margin = dplyr::first(margin),
      contradictions = dplyr::first(contradiction_count),
      corroborated = dplyr::first(.data[[corr]]),
      surname_evidence = dplyr::first(surname_evidence),
      held = dplyr::first(npi_held_by_other_certificant),
      .groups = "drop")
  plausible <- best$contradictions == 0L & best$best_score >= r$plausible
  fails <- function(cond, code) ifelse(cond, code, NA_character_)
  why <- cbind(
    fails(best$n_at_top > 1L, "tied_top"),
    fails(best$best_score < r$accept, sprintf("score_below_%s", r$accept)),
    fails(!is.na(best$margin) & best$margin < r$margin, sprintf("margin_below_%s", r$margin)),
    fails(!best$corroborated, "no_non_name_corroboration"),
    fails(best$surname_evidence == "different", "surname_changed_unexplained"),
    fails(best$held %in% TRUE, "npi_held_by_other_certificant"))
  reasons <- apply(why, 1, function(x) paste(x[!is.na(x)], collapse = ";"))
  best |>
    dplyr::mutate(
      decision = dplyr::case_when(!plausible ~ "UNRESOLVED",
                                  !nzchar(reasons) ~ "ACCEPT",
                                  TRUE ~ "REVIEW"),
      emptied = n_contradiction_free == 0L,
      decision_reason = dplyr::case_when(
        decision == "ACCEPT" ~ paste0("accept:unique_top;",
                                      if_else(is.na(margin), "unopposed", paste0("margin=", margin))),
        decision == "REVIEW" ~ paste0("review:", reasons),
        emptied ~ "unresolved:every_candidate_contradicted",
        TRUE ~ sprintf("unresolved:best_below_plausible_%s", r$plausible)),
      variant = variant) |>
    dplyr::select(amcb_id, variant, decision, decision_reason, best_npi, tied_npis, best_score,
                  runner_up_score, margin, n_candidates, n_contradiction_free, emptied)
}

#' Where a pair's contradiction comes from
#'
#' A contradiction is only the DIRECTORY's evidence when the directory
#' supplied the fact. The first run showed why this has to be separated: all
#' 578 given-name conflicts on class-3 links were the matcher's own
#' first-initial rule (same surname and initial, different given name), with
#' Trilliant carrying exactly the name NPPES carries. Counting those as
#' "Trilliant contradicts" would credit the directory with a rule the matcher
#' already applied and relaxed on purpose.
#' @param contra_given,contra_middle,contra_profession,contra_grad_year [logical]
#' @param trl_name_equals_nppes [logical] the directory's given and surname equal
#'   the NPI's current NPPES name; NA when NPPES has no name for it.
#' @return "none"; "directory_fields" (graduation year or current profession);
#'   "directory_name" (a name conflict where the directory's name differs from
#'   NPPES, or NPPES has none); "name_rule" (a name conflict on the very name
#'   NPPES carries: a disagreement with the matcher's rules, not new evidence).
trl_contradiction_source <- function(contra_given, contra_middle, contra_profession, contra_grad_year,
                                     trl_name_equals_nppes) {
  name_conflict <- contra_given | contra_middle
  dplyr::case_when(contra_profession | contra_grad_year ~ "directory_fields",
                   name_conflict & !(trl_name_equals_nppes %in% TRUE) ~ "directory_name",
                   name_conflict ~ "name_rule",
                   TRUE ~ "none")
}

#' What Trilliant says about a certificant, in the experiment's outcomes
#'
#' For a certificant the linkage already resolved:
#'   confirms          the incumbent NPI is the single best candidate, carries no
#'                     contradiction, and a non-name field supports it
#'   contradicts       the directory supplies a contradiction of the incumbent
#'                     (see trl_contradiction_source()), or another NPI would be
#'                     ACCEPTed over it
#'   name_rule_conflict the incumbent's only contradiction is a name rule
#'                     applied to the name NPPES already carries: reported, and
#'                     never credited to the directory
#'   no_useful_evidence otherwise (incumbent absent from the directory,
#'                     unsupported, or tied)
#' For one it did not:
#'   chooses_between_competing  ACCEPT for a certificant quarantined as tied,
#'                     contested or unruled-out
#'   plausible_new_npi ACCEPT or REVIEW for an unmatched certificant
#'   no_useful_evidence otherwise
#' @param stratum [character] from trl_stratum().
#' @param incumbent_found,incumbent_confirms,displaced [logical]
#' @param incumbent_contra_source [character] from trl_contradiction_source(); NA
#'   when the incumbent is not in the directory.
#' @param decision [character] ACCEPT / REVIEW / UNRESOLVED.
#' @return outcome label.
trl_outcome <- function(stratum, incumbent_found, incumbent_confirms, incumbent_contra_source,
                        displaced, decision) {
  existing <- startsWith(stratum, "1")
  dplyr::case_when(
    existing & !incumbent_found ~ "no_useful_evidence",
    existing & (incumbent_contra_source %in% c("directory_fields", "directory_name") | displaced) ~ "contradicts",
    existing & incumbent_contra_source %in% "name_rule" ~ "name_rule_conflict",
    existing & incumbent_confirms ~ "confirms",
    existing ~ "no_useful_evidence",
    stratum == "2_ambiguous" & decision == "ACCEPT" ~ "chooses_between_competing",
    stratum == "3_unmatched" & decision %in% c("ACCEPT", "REVIEW") ~ "plausible_new_npi",
    TRUE ~ "no_useful_evidence")
}

#' Which experiment stratum a frozen-linkage row belongs to
#'
#' 1a  an existing link at the matcher's strongest evidence (primary tier,
#'     evidence class 1 or 2): the high-confidence stratum
#' 1b  every other existing link (class 3-4, nursing and fuzzy tiers)
#' 2   quarantined without an NPI: tied, contested, unruled-out, class-5 held out
#' 3   no candidate at all
#' @return "1a_existing_high_confidence", "1b_existing_other", "2_ambiguous", "3_unmatched".
trl_stratum <- function(linkage_tier, name_evidence_class, npi) {
  has_npi <- !is.na(npi) & nzchar(npi)
  dplyr::case_when(
    has_npi & linkage_tier %in% "primary_midwifery" & name_evidence_class %in% c("1", "2") ~
      "1a_existing_high_confidence",
    has_npi ~ "1b_existing_other",
    linkage_tier %in% "unmatched" ~ "3_unmatched",
    TRUE ~ "2_ambiguous")
}
