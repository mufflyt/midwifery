# =============================================================================
# Credential filter
# =============================================================================
# Keep rows whose credential field does NOT contain any excluded credential.
# Word-boundary match so "MD" doesn't also match "DMD"; default excludes
# physicians (MD, DO) so APRNs -- including CNMs -- pass through, the inverse
# of isochrones' R/C-filter_physician_compare_physicians_only.R, which keeps
# only MD/DO.
# =============================================================================

exclude_by_credential <- function(credential, exclude = c("MD", "DO")) {
  pattern <- paste0("\\b(", paste(exclude, collapse = "|"), ")\\b")
  !grepl(pattern, credential, ignore.case = TRUE)
}
