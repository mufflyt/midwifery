# =============================================================================
# Reaching catalog values from prose
# =============================================================================
# The contract, deliberately the same one ~/isochrones/manuscript/R/11_inline_stats.R
# offers, so that moving between the two manuscripts costs nothing:
#
#   mw_stat("linkage.matched_pct", "%.1f")   formatted value, NA if absent
#   mw_safe_stat(...)                        same, but in dev mode a missing
#                                            value renders as **[PENDING]**
#                                            instead of stopping the render
#   mw_n(x)                                  integer with thousands separators
#   mw_pval(p)                               Green Journal P-value convention
#
# The dev-mode split is the important part. During drafting a missing number
# must be VISIBLE in the output -- a bold [PENDING] in the middle of a sentence
# -- because a placeholder that renders as blank or as "NA" reads like prose
# and ships. At production render MANUSCRIPT_DEV_MODE is unset and the same
# missing value stops the build instead.
# =============================================================================

.mw_catalog <- NULL

#' Load the catalog into the session
#'
#' @param root [character]: repository root.
#' @param rebuild [logical]: ignored; present so the call site reads the same as
#'   the isochrones one. This catalog is ALWAYS rebuilt -- see
#'   build_stats_catalog.R for why caching it would reintroduce the defect.
#' @return the catalog, invisibly.
mw_init_stats <- function(root = ".", rebuild = TRUE) {
  .mw_catalog <<- mw_build_catalog(root)
  invisible(.mw_catalog)
}

mw_dev_mode <- function() nzchar(Sys.getenv("MANUSCRIPT_DEV_MODE"))

.mw_get <- function(path, catalog = .mw_catalog) {
  if (is.null(catalog)) return(NULL)
  parts <- strsplit(path, ".", fixed = TRUE)[[1]]
  v <- catalog
  for (p in parts) {
    if (!is.list(v) || is.null(v[[p]])) return(NULL)
    v <- v[[p]]
  }
  v
}

#' A catalog value, formatted
#'
#' @param path [character]: dot-separated key, eg "linkage.matched_pct".
#' @param fmt [character]: sprintf format, or NULL for the raw value.
#' @return [character] or the raw value.
mw_stat <- function(path, fmt = NULL, catalog = .mw_catalog) {
  v <- .mw_get(path, catalog)
  if (is.null(v) || (is.atomic(v) && length(v) == 1L && is.na(v))) return(NA)
  if (is.null(fmt)) return(v)
  sprintf(fmt, v)
}

#' A catalog value that the manuscript cannot do without
#'
#' @inheritParams mw_stat
#' @return formatted value; **[PENDING]** in dev mode when absent.
mw_safe_stat <- function(path, fmt = NULL, catalog = .mw_catalog) {
  v <- mw_stat(path, fmt, catalog)
  ok <- !(length(v) == 1L && (is.null(v) || (is.atomic(v) && is.na(v))))
  if (ok) return(v)
  if (mw_dev_mode()) return(sprintf("**[PENDING: %s]**", path))
  stop(sprintf(paste0(
    "\nMISSING STATISTIC: '%s'\n",
    "This value appears in the manuscript text and has no value in the catalog.\n",
    "Either the artifact that feeds it is absent, or the key is misspelt.\n",
    "Check manuscript/R/build_stats_catalog.R, or set MANUSCRIPT_DEV_MODE=1\n",
    "to render a draft with placeholders."), path), call. = FALSE)
}

#' A count, with thousands separators
mw_n <- function(path, catalog = .mw_catalog) {
  v <- .mw_get(path, catalog)
  if (is.null(v) || is.na(v)) return(mw_safe_stat(path))
  formatC(as.numeric(v), format = "d", big.mark = ",")
}

#' A P value in Green Journal style
#'
#' The journal asks for exact values, and for P<.001 below that -- with no
#' leading zero, which is the house convention and the reason this is a
#' function rather than a sprintf at each call site.
mw_pval <- function(p) {
  if (is.null(p) || is.na(p)) return("**[PENDING: P]**")
  if (p < .001) return("*P*<.001")
  sub("0\\.", ".", sprintf("*P*=%.3f", p))
}

#' A percentage with its Wilson interval, as the journal sets them
mw_pct_ci <- function(pct, lo, hi, digits = 1) {
  f <- paste0("%.", digits, "f")
  sprintf("%s%% (95%% CI %s-%s)", sprintf(f, pct), sprintf(f, lo), sprintf(f, hi))
}

#' Word counts for the rendered manuscript
#'
#' Obstetrics & Gynecology limits the précis (<=25 words) and the structured
#' abstract (<=300 words), and asks separately for the main-text count from
#' Introduction through the Conclusion, excluding abstract, tables, table
#' legends and references.
#'
#' COUNTED FROM THE RENDERED .docx, NOT THE .qmd. This is the whole point, and
#' it is the convention ~/isochrones/manuscript/R/wordcount_helpers.R
#' established for the same reason: the source is full of inline `r ...`
#' expressions that expand to real values at render time. Counting the source
#' counts the code, not the prose, and the two differ by hundreds of words in
#' this manuscript.
#'
#' Consequence for render order: the manuscript must be rendered BEFORE the
#' title page, because the title page reports the manuscript's counts. When the
#' .docx is absent the counts degrade to a visible marker rather than a number,
#' so a title page can still be drafted.
#'
#' @param qmd_path [character]: path to the .qmd; the sibling .docx is read.
#' @return [list] precis, abstract, body.
mw_wordcount <- function(qmd_path) {
  docx <- sub("[.]qmd$", ".docx", qmd_path)
  src0 <- if (file.exists(qmd_path)) readLines(qmd_path, warn = FALSE) else character(0)
  miss <- list(tables = length(grep("^```\\{r tbl", src0)),
               figures = length(grep("^```\\{r fig", src0)),
               precis = "**[render the manuscript first]**",
               abstract = "**[render the manuscript first]**",
               body = "**[render the manuscript first]**")
  if (!file.exists(docx)) return(miss)

  con <- unz(docx, "word/document.xml")
  xml <- tryCatch(paste(readLines(con, warn = FALSE), collapse = ""),
                  error = function(e) NA_character_,
                  finally = try(close(con), silent = TRUE))
  if (is.na(xml)) return(miss)

  paras <- strsplit(gsub("</w:p>", "\n", xml, fixed = TRUE), "\n", fixed = TRUE)[[1]]
  paras <- trimws(gsub("<[^>]+>", "", paras))
  paras <- paras[nzchar(paras)]

  nwords <- function(v) sum(vapply(v, function(x)
    length(strsplit(trimws(x), "\\s+")[[1]]), integer(1)))
  find <- function(rx) which(grepl(rx, paras, ignore.case = TRUE))[1]

  i_abs  <- find("^Abstract$")
  i_intro <- find("^Introduction$")
  i_tbl  <- find("^Tables$")
  i_ref  <- find("^References$")
  end_body <- min(c(i_tbl, i_ref, length(paras) + 1L), na.rm = TRUE) - 1L

  # Table and figure counts come from the SOURCE, not the .docx: they are
  # structural (one chunk per exhibit) and a caption search in the rendered XML
  # would also catch the words "Table 1" wherever the body cites one.
  src <- readLines(qmd_path, warn = FALSE)
  n_tbl <- length(grep("^```\\{r tbl", src))
  n_fig <- length(grep("^```\\{r fig", src))

  list(
    tables   = n_tbl,
    figures  = n_fig,
    precis   = if (!is.na(i_abs)) {
                 pr <- grep("^Précis", paras)
                 if (length(pr)) nwords(sub("^Précis:\\s*", "", paras[pr[1]])) else NA_integer_
               } else NA_integer_,
    abstract = if (!is.na(i_abs) && !is.na(i_intro))
                 nwords(paras[(i_abs + 1L):(i_intro - 1L)]) else NA_integer_,
    body     = if (!is.na(i_intro)) nwords(paras[i_intro:end_body]) else NA_integer_
  )
}
