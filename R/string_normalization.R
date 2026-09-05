# Shim: enhanced_name_parsing.R (and friends) call
# here::here("R", "string_normalization.R"), which resolves inside THIS repo.
# Forward to the canonical implementation, which now lives in the mysterynpi
# PACKAGE rather than a sibling checkout.
#
# CYCLE 4 established the rule: a missing authoritative engine fails LOUDLY
# with instructions, and never falls back to a local reimplementation, because
# a second copy of a name-normalisation rule is how two pipelines quietly
# disagree about who matched whom. The 2026-09 migration keeps the rule and
# upgrades the mechanism: a versioned package with an assertable contract
# replaces source()-ing a path in another repository -- the path could move
# without any version changing (it did; that was Cycle 4), while a package
# version pins behaviour and mysterynpi's own CI proves the functions this
# repo relies on byte-identical to the isochrones originals (its
# test-drop-in-parity suite). Equivalence was additionally verified against
# THIS repo's roster: 23,543 distinct name values, every normalisation
# surface identical (2026-09-05).
if (!requireNamespace("mysterynpi", quietly = TRUE)) {
  stop(paste0(
    "The canonical name-normalisation engine is the mysterynpi package, ",
    "and it is not installed.\n",
    "  Fix: remotes::install_github(\"mufflyt/mysterynpi@v0.2.0\")\n",
    "       (private repo: authenticate gh first, or install from a local ",
    "checkout with R CMD INSTALL)\n",
    "  Do NOT vendor a local copy -- name normalisation must have exactly ",
    "one definition across the pipelines that compare names."),
    call. = FALSE)
}
if (utils::packageVersion("mysterynpi") < "0.2.0") {
  stop(sprintf(paste0(
    "mysterynpi %s is installed but this pipeline pins >= 0.2.0: the ",
    "surname/suffix/nickname agreement surface it relies on arrived there. ",
    "Upgrade rather than working around."),
    utils::packageVersion("mysterynpi")), call. = FALSE)
}

normalize_string          <- mysterynpi::normalize_string
normalize_name_columns    <- mysterynpi::normalize_name_columns
normalize_physician_names <- mysterynpi::normalize_physician_names
sql_npi_name              <- mysterynpi::sql_npi_name
needs_normalization       <- mysterynpi::needs_normalization
extract_first_initial     <- mysterynpi::extract_first_initial

# Composition, not reimplementation: the canonical normalize_name_key() was
# always gsub-collapse over normalize_string(), and stays exactly that.
normalize_name_key <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  gsub("\\s+", " ", mysterynpi::normalize_string(x))
}
