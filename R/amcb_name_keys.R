# =============================================================================
# AMCB name keys -- the join keys used to link the AMCB roster to NPPES
# =============================================================================
#
# WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT.
#
# This file does NOT define name normalisation. It has exactly one source of
# truth for that, the canonical normalize_string() in the isochrones project,
# and it fails loudly if that is unreachable rather than falling back to a
# local reimplementation. The standing rule in R/string_normalization.R applies
# here verbatim: a second copy of a name-normalisation rule is how two
# pipelines quietly disagree about who matched whom.
#
# What it DOES define is the AMCB-specific key construction layered on top:
# how the roster's fused first/middle field is split, and how absence is
# represented. That logic is genuinely local to this cohort -- NPPES has
# separate first and middle columns and AMCB does not -- so it belongs here
# rather than in the shared normaliser.
#
# THE DEFECT THIS FIXES (2026-08-10). match_amcb_to_npi.R reused norm_name()
# from scripts/match_enthealth_to_npi.R, which is toupper(trimws(...)) and
# nothing more. It does NOT delete accented characters -- it PRESERVES them:
#
#   norm_name("Álvarez")     -> "ÁLVAREZ"      (not "ALVAREZ", not "LVAREZ")
#   first_initial("Álvarez") -> "Á"            (never equal to NPPES "A")
#
# Every matching strategy joins on exact first name or exact first initial, so
# an accented name could not match its unaccented NPPES spelling by ANY route.
# The measured signature in the frozen linkage confirms it: among the 27 roster
# rows carrying non-ASCII name characters, sensitivity_fuzzy runs 26% against
# 1.5% cohort-wide -- a 17x enrichment -- because the accent survives to
# strategy 3 and is scored as a one-character Levenshtein edit on the surname.
# unmatched runs 30% against 10.4%. Those are real midwives demoted out of the
# primary tier, or lost, by a normalisation gap alone.
#
# normalize_string() already handles this correctly (NFC, German romanisation,
# then Latin-ASCII transliteration), and also folds the curly apostrophe in
# names like D'Annunzio to ASCII. The fix is to CALL it, not to write another.
#
# Run the regression tests: Rscript tests/test_amcb_name_normalization.R
# =============================================================================

local({
  iso <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
  target <- file.path(iso, "string_normalization.R")
  if (!file.exists(target)) {
    stop(sprintf(paste0(
      "Canonical string_normalization.R not found.\n",
      "  Looked in : %s\n",
      "  Fix: point ISOCHRONES_R at the isochrones R/ directory, e.g.\n",
      "         Sys.setenv(ISOCHRONES_R = \"~/isochrones/R\")\n",
      "  Do NOT vendor a local copy -- name normalisation must have exactly\n",
      "  one definition across the pipelines that compare names."), target),
      call. = FALSE)
  }
  source(target)
  if (!exists("normalize_string")) {
    stop("normalize_string() not defined by ", target, call. = FALSE)
  }
})

# stringi is what performs the transliteration. Without it normalize_string()
# degrades to a warning and plain toupper(), which is precisely the broken
# behaviour this file exists to prevent -- so refuse to run rather than
# silently reintroduce it.
if (!requireNamespace("stringi", quietly = TRUE)) {
  stop(paste("stringi is required for AMCB name matching: without it",
             "normalize_string() cannot transliterate accented names and",
             "every non-ASCII midwife silently fails to match."), call. = FALSE)
}

#' Canonical name key: transliterated, upper-cased, whitespace-collapsed.
#'
#' NA in, NA out. Callers that need "" for a join must coalesce explicitly --
#' see amcb_blank_na() -- so that absence is never converted to a value by
#' accident. Internal whitespace is collapsed here because normalize_string()
#' only trims the ends, and the AMCB roster contains doubled internal spaces.
#' PARENTHESISED NICKNAMES ARE NOT NAME EVIDENCE (2026-08-30).
#'
#' The roster publishes preferred names inline: "Cynthia (Cindi)", "Patty
#' (Pepita)", "Anna (Katie)". normalize_string() transliterates and upper-cases
#' but does not remove punctuation, so the bracket survived into the key and
#' amcb_split_first() handed the middle-name slot a literal "(":
#'
#'   "Cynthia (Cindi)"  ->  given "CYNTHIA", middle "(CINDI)",  initial "("
#'
#' "(" is not equal to any NPPES middle initial, so every such row registered a
#' middle-initial CONFLICT against every candidate carrying a middle name, and
#' the veto below deleted the candidate set. All 9 affected roster rows failed:
#' 7 unmatched and 2 tied, none resolved, against a 9.4% unmatched baseline.
#' The nickname is real information about the person and no information at all
#' about which NPI is hers, so it is dropped from the key rather than compared.
#'
#' Stripping happens HERE, in the AMCB key layer, not in normalize_string():
#' other callers of the canonical normaliser are not parsing a roster that uses
#' this convention, and a punctuation rule added there would reach them all.
#' WORD-INTERNAL BRACKETS ARE SPELLING, NOT A NICKNAME. The roster carries both
#' conventions and they mean opposite things:
#'
#'   "Cynthia (Cindi) A."   a separate token  -> an alternate name, drop it
#'   "C(arolyn) Diane"      inside one token  -> optional letters, KEEP them
#'
#' Deleting the group in the second case leaves a given name of "C", which is
#' not a name -- it is a blocking key that joins to every NPPES first name
#' recorded as a bare initial. So the two cases are separated by whether the
#' bracket abuts a letter, and only the standalone form is dropped.
amcb_strip_parenthetical <- function(x) {
  # 1. Word-internal: unwrap, keep the letters.  C(AROLYN) -> CAROLYN
  out <- gsub("([A-Z'])\\(([^)]*)\\)", "\\1\\2", x)
  # 2. Standalone group: the published nickname form.
  out <- gsub("\\([^)]*\\)", " ", out)
  # 3. An UNCLOSED bracket opens a nickname that runs to the end of the field.
  #    Dropping it can only lose an alternate name; keeping it would promote
  #    that alternate into the middle-name slot, which is the defect itself.
  out <- gsub("\\([^)]*$", " ", out)
  # "]" FIRST inside the class: the portable way to mean a literal bracket.
  # Written as [()\\[\\]] the escapes are ambiguous in TRE and the class
  # terminated early, leaving the stray untouched.
  gsub("[][()]", " ", out)
}

amcb_name_key <- function(x) {
  if (is.null(x) || length(x) == 0L) return(character(0))
  out <- normalize_string(as.character(x))
  out <- amcb_strip_parenthetical(out)
  out <- gsub("\\s+", " ", trimws(out))
  out[is.na(x)] <- NA_character_
  out
}

#' Does this field carry identity information?
#'
#' Never use a naked nzchar() to ask this. nzchar(NA_character_) is TRUE, which
#' reads missingness as evidence -- the 2026-08-08 defect that made every absent
#' middle name agree with every other absent middle name.
amcb_has_name_information <- function(x) !is.na(x) & nzchar(x)

#' Normalised key with absence rendered as "", for use as a join key.
amcb_blank_na <- function(x) {
  k <- amcb_name_key(x)
  k[is.na(k)] <- ""
  k
}

#' First initial of a normalised name, or NA when there is no name.
#'
#' Returns NA rather than "" for missing input so a caller cannot read absence
#' as a value. Taken after transliteration, so "Álvarez" yields "A" and joins
#' against NPPES "ALVAREZ" -- the whole point of this file.
amcb_first_initial <- function(x) {
  k <- amcb_name_key(x)
  out <- substr(k, 1L, 1L)
  out[is.na(k) | !nzchar(k)] <- NA_character_
  out
}

# Surname particles. A token match on "DE", "VAN" or "ST" is not evidence of
# identity -- it is evidence of a naming convention -- and admitting them would
# join every DE LA CRUZ to every DE LEON sharing a given name.
AMCB_SURNAME_PARTICLES <- c(
  "DE", "DEL", "DELA", "DELAS", "DELOS", "LA", "LAS", "LE", "LOS", "DA", "DAS",
  "DI", "DO", "DOS", "VAN", "VANDER", "VON", "DER", "DEN", "TER", "TEN",
  "ST", "STE", "MC", "MAC", "EL", "AL", "BIN", "IBN", "BEN", "ABU", "Y", "I")

# A shorter token carries too little information to stand alone as surname
# evidence once the rest of the compound is discarded.
AMCB_MIN_SURNAME_TOKEN <- 4L

#' Split a normalised surname into its components.
#'
#' WHY THIS EXISTS. AMCB and NPPES routinely disagree about how a compound
#' surname is recorded: AMCB holds "MCCARTHY-DERVIN" where NPPES holds
#' "MCCARTHY", or AMCB splits "HARVEY CAPISTA" across its middle and last
#' fields where NPPES keeps it whole. None of the exact or Levenshtein
#' strategies can span a DROPPED name component -- an edit distance of 2 cannot
#' cross seven missing characters -- so these fail silently as "no candidate".
#' Measured in the crosswalk: hyphenated surnames are 27.1% unmatched against
#' 9.8% for unhyphenated, a 2.8x gap over 791 roster rows.
#'
#' Splits on hyphen and whitespace, drops particles and short tokens, and
#' returns unique components. Returns character(0) when nothing survives, so a
#' name made entirely of particles yields no join key rather than a weak one.
amcb_surname_tokens <- function(x) {
  k <- amcb_name_key(x)
  if (is.na(k) || !nzchar(k)) return(character(0))
  toks <- strsplit(gsub("[^A-Z']+", " ", k), "\\s+")[[1]]
  toks <- toks[nzchar(toks)]
  toks <- toks[!toks %in% AMCB_SURNAME_PARTICLES]
  toks <- toks[nchar(toks) >= AMCB_MIN_SURNAME_TOKEN]
  unique(toks)
}

#' Vectorised surname tokens as a long (index, token) data frame.
#'
#' Returned long rather than as a list column because every caller joins on the
#' token; a list column would have to be unnested at each call site.
amcb_surname_token_table <- function(x, id) {
  stopifnot(length(x) == length(id))
  lst <- lapply(x, amcb_surname_tokens)
  n <- lengths(lst)
  data.frame(id = rep(id, n), token = unlist(lst, use.names = FALSE),
             stringsAsFactors = FALSE)
}

#' Split the AMCB first_name field into given name and trailing middle tokens.
#'
#' AMCB fuses middle names into first_name ("Julie Ann", "René Richard"): the
#' first token is the given name, the remainder is middle. Returns a list of
#' two character vectors, both already normalised.
amcb_split_first <- function(first_name) {
  k <- amcb_blank_na(first_name)
  given <- sub("\\s.*$", "", k)
  trailing <- trimws(sub("^[^ ]*", "", k))
  list(given = given, middle_from_first = trailing)
}

#' Middle-name TOKENS, initials included.
#'
#' Unlike amcb_given_tokens(), single-letter tokens are KEPT. A recorded middle
#' initial is the only middle-name evidence most NPPES rows carry; dropping it
#' would make every initial-only row uninformative rather than comparable, and
#' comparability is the whole point of the middle-name axis.
#'
#' Returns a LIST of character vectors, one per input, so callers compare sets
#' rather than positions. amcb_middle_agreement() in R/amcb_match_rules.R is
#' the only rule that interprets them.
amcb_middle_tokens <- function(x) {
  k <- amcb_blank_na(x)
  lapply(strsplit(k, "[^A-Z']+"), function(t) unique(t[nzchar(t)]))
}

# =============================================================================
# Personal-name parsing for external author strings (humaniformat)
# =============================================================================
#
# WHY NOT sub(",.*") AND FIRST-TOKEN. Repository author strings are not
# "Last, First". Observed in the ACME harvest (5,404 degree works): 764 contain
# a period, 54 contain two or more commas, 119 have no comma at all, and some
# carry credentials or titles inline. A split-on-first-comma plus take-first-
# token produced, verbatim:
#
#   "Wang, MSN, CRNP, Mary"          -> given name "MSN,"      credentials
#   "Williams, W. Jon"               -> given name "W."        initial-first
#   "Bass, Dr. M. Dustin"            -> given name "Dr."       title
#   "Schneider, Barbara St. Pierre"  -> given name "Barbara"   ok by luck
#
# Two of those can never match anything; the third matches the wrong people.
#
# BOTH SIDES ARE PARSED THE SAME WAY. Parsing only the external side and
# comparing against a naively split roster reintroduces the asymmetry that
# caused false matches here before.
#
# COMPARISON IS ON TOKEN SETS, NOT POSITION. "Williams, W. Jon" and
# "Jon W Williams" are the same person; their given-name token SETS share JON.
# A positional first-token rule scores them as different. A shared FULL token
# (>=2 characters) is required -- initials may corroborate but never identify,
# since "W." matches every W.

# Credentials and titles seen in these repositories. Stripped BEFORE parsing:
# humaniformat has no way to know CRNP is not a middle name.
AMCB_NAME_NOISE <- c(
  "DNP","DNSC","DNS","PHD","EDD","MD","DO","MSN","MSC","MS","MA","MPH",
  "BSN","BS","BA","RN","APRN","ARNP","CNM","CM","CNS","CRNP","CRNA",
  "NP","FNP","WHNP","PNP","ANP","AGNP","IBCLC","LCCE","FACNM","FAAN",
  "RNC","LM","CPM","DR","PROF","MR","MRS","MS","MISS","JR","SR",
  "II","III","IV")

#' Strip credential and title TOKENS from a personal-name string.
#'
#' TOKEN-BASED ON PURPOSE. The first version used a \\b-delimited regex
#' alternation, which destroyed accented surnames: in "Mróz" the "ó" is not an
#' ASCII word character, so \\bMr\\b matched INSIDE the name and the parser
#' returned a surname of "OZ". That is the same population the transliteration
#' work exists to protect, broken by the cleaner meant to help it.
#'
#' Splitting on delimiters and dropping whole tokens cannot match a substring,
#' so no name can be truncated by this function.
amcb_strip_name_noise <- function(x) {
  vapply(as.character(x), function(s) {
    if (is.na(s)) return(NA_character_)
    parts <- strsplit(s, "[[:space:],]+")[[1]]
    parts <- parts[nzchar(parts)]
    bare <- toupper(gsub("[.]", "", parts))
    keep <- parts[!(bare %in% AMCB_NAME_NOISE)]
    # Periods carry no identity information once titles are gone.
    out <- gsub("[.]", " ", paste(keep, collapse = " "))
    gsub("[[:space:]]+", " ", trimws(out))
  }, character(1), USE.NAMES = FALSE)
}

#' Parse an author string into first / middle / last using humaniformat.
#'
#' Handles both "Last, First M" (reversed before parsing) and "First M Last".
#' @return data.frame(first, middle, last), normalised with amcb_name_key().
amcb_parse_person <- function(x) {
  if (!requireNamespace("humaniformat", quietly = TRUE)) {
    stop("humaniformat is required for author-name parsing", call. = FALSE)
  }
  # Preserve the "Last, First" signal: stripping removes commas, so record
  # whether one was present BEFORE cleaning and restore it for format_reverse().
  had_comma <- grepl(",", as.character(x))
  cleaned <- amcb_strip_name_noise(x)
  raw <- ifelse(had_comma & !is.na(cleaned),
                sub("^([^ ]+)[[:space:]]+", "\\1, ", cleaned), cleaned)
  # format_reverse() turns "Last, First" into "First Last"; it is a no-op on
  # strings without a comma, so it is safe to apply to the whole vector.
  rev <- humaniformat::format_reverse(raw)
  p <- humaniformat::parse_names(rev)
  data.frame(
    first  = amcb_name_key(p$first_name),
    middle = amcb_name_key(p$middle_name),
    last   = amcb_name_key(p$last_name),
    stringsAsFactors = FALSE)
}

#' Given-name tokens of length >= 2 (initials excluded).
#'
#' Initials are dropped for MATCHING because "W." is compatible with every W;
#' they are still available in the parsed columns for reporting.
amcb_given_tokens <- function(first, middle = NULL) {
  both <- trimws(paste(coalesce_chr(first), coalesce_chr(middle)))
  lapply(strsplit(both, "[^A-Z']+"), function(t) {
    t <- t[nchar(t) >= 2]
    unique(t[nzchar(t)])
  })
}

coalesce_chr <- function(x) if (is.null(x)) "" else ifelse(is.na(x), "", x)

#' Do two parsed people share a surname AND at least one full given-name token?
amcb_person_matches <- function(last_a, given_a, last_b, given_b) {
  same_last <- !is.na(last_a) & !is.na(last_b) & nzchar(last_a) & last_a == last_b
  shared <- mapply(function(x, y) length(intersect(x, y)) > 0, given_a, given_b)
  same_last & shared
}
