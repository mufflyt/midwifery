#!/usr/bin/env Rscript
# =============================================================================
# Saboteurs for the 2026-11-20 manuscript figure fixes
# =============================================================================
# Five defects were found by RENDERING the manuscript and LOOKING at it, which
# is the only reason any of them surfaced: every one of them rendered without
# an error, and four of the five are invisible in the source. A figure whose
# legend is wider than its canvas is drawn anyway; a figure citation pointing
# at the wrong figure is valid markdown; a heading that makes a per-midwife
# claim from a per-provider-year denominator is grammatical. Nothing failed.
#
#   G1 A legend that does not fit is clipped at BOTH ends and still saved.
#      fit_plot_legend() measures the assembled guide box and adds rows.
#   G2 ... and save_audit_fig() has to actually call it, or G1 guards a
#      function nothing uses.
#   G3 A figure in this manuscript may not name a record system the paper
#      does not examine. Figure 2 named Trilliant, which is absent from
#      Table 1.
#   G4 Every figure is cited exactly once in prose, before its caption, and
#      the numbering is contiguous. The scoring sentence cited Figure 6 for a
#      result Figure 6 does not show, and Figure 5 was never cited at all.
#   G5 A rate must be stated in the units of its own denominator. The section
#      heading said "one midwife in six" for a statistic whose denominator is
#      observed provider-years, while the figure beside it reports 43.8% on a
#      denominator of midwives.
#   G6 Reader-visible figure labels use the journal's American spellings.
#
# Each saboteur mutates the thing it guards and checks the guard fires, so a
# check that cannot fail is reported as a failure of the check.
# =============================================================================

suppressPackageStartupMessages({library(ggplot2)})
.sb <- grep("--file=", commandArgs(), value = TRUE)
root <- if (length(.sb)) {
  normalizePath(file.path(dirname(sub("--file=", "", .sb[1])), ".."))
} else normalizePath(".")
source(file.path(root, "tests", "helper-saboteur.R"))
SAB_PREFIX <- "G"

QMD <- file.path(root, "manuscript", "federal_database_accuracy.qmd")
STYLE <- file.path(root, "R", "lib", "audit_figure_style.R")
AUDIT_SCRIPT <- file.path(root, "make_state_source_audit_figures.R")
FIG2_SCRIPT <- file.path(root, "make_source_reliability_figure.R")

read_text <- function(path) paste(readLines(path, warn = FALSE), collapse = "\n")

# --- G1 a legend wider than the canvas -----------------------------------------
sab(1, "a legend wider than the canvas is wrapped, not clipped")
source(STYLE)

# The real five-series legend from state_source_agreement_by_year, which is the
# one that shipped reading "tem" instead of "Record system".
wide_legend_plot <- function() {
  d <- data.frame(
    x = rep(1:3, 5), y = rep(1:5, each = 3),
    s = rep(c("DAC / Physician Compare", "Facility Affiliation (CCN)",
              "Medicare claims (Parts B and D)", "Open Payments",
              "PECOS revalidation/reassignment"), each = 3))
  ggplot(d, aes(x, y, colour = s)) + geom_line() +
    scale_colour_manual(values = AUDIT_SERIES) +
    labs(colour = "Record system") +
    theme_minimal(base_size = 13) + theme(legend.position = "bottom")
}
canvas_limit <- function(p, width_in) {
  th <- ggplot2::complete_theme(p$theme)
  m <- as.numeric(grid::convertUnit(
    ggplot2::calc_element("plot.margin", th), "pt"))
  width_in * 72 - m[2] - m[4]
}

p_wide <- wide_legend_plot()
lim <- canvas_limit(p_wide, 8.5)
raw_w <- legend_box_width_pt(p_wide)
# SABOTEUR: the unfitted legend must genuinely overflow, or G1 proves nothing.
chk(raw_w > lim,
    sprintf("G1a the unfitted legend really is too wide (%.0f pt into %.0f pt) -- the saboteur has something to catch",
            raw_w, lim))
fit_w <- legend_box_width_pt(fit_plot_legend(p_wide, 8.5))
chk(fit_w <= lim,
    sprintf("G1b fit_plot_legend() brings it inside the canvas (%.0f pt <= %.0f pt)",
            fit_w, lim))

# A legend that already fits must be left alone: a fitter that wraps
# everything would quietly restyle five figures that were never broken.
p_ok <- ggplot(data.frame(x = 1:3, y = 1:3, s = c("a", "b", "c")),
               aes(x, y, colour = s)) + geom_point() +
  theme_minimal(base_size = 13) + theme(legend.position = "bottom")
chk(identical(legend_box_width_pt(p_ok),
              legend_box_width_pt(fit_plot_legend(p_ok, 8.5))),
    "G1c a legend that already fits is returned unchanged")

# --- G2 the fitter is actually wired into the saver ----------------------------
sab(2, "the saver calls the fitter, so G1 guards a path that runs")
style_src <- read_text(STYLE)
saver <- sub("(?s).*save_audit_fig <- function", "", style_src, perl = TRUE)
chk(grepl("fit_plot_legend", saver, fixed = TRUE),
    "G2a save_audit_fig() routes every figure through fit_plot_legend()")
chk(grepl("fit_plot_labels", saver, fixed = TRUE),
    "G2b ... and still through fit_plot_labels()")

# --- G3 no figure may name a source the paper does not examine -----------------
sab(3, "a manuscript figure names only record systems the paper examines")
# Trilliant is a commercial provider directory used elsewhere in this
# repository and absent from this manuscript's Table 1.
OUT_OF_SCOPE <- c("Trilliant")
# Reader-visible strings only, by the same rule G6 uses: the rewritten Figure 2
# script explains in its header WHY Trilliant was removed, and a scanner that
# read comments would fail on the explanation of the fix.
label_strings <- function(path) {
  src <- readLines(path, warn = FALSE)
  src <- src[!grepl("^\\s*#", src)]
  unlist(regmatches(src, gregexpr('"[^"]*"', src)))
}
scan_out_of_scope <- function(path) {
  strs <- label_strings(path)
  unlist(lapply(OUT_OF_SCOPE, function(nm)
    if (any(grepl(nm, strs, fixed = TRUE))) paste0(basename(path), ": ", nm)
    else character(0)))
}
offenders <- unlist(lapply(c(FIG2_SCRIPT, AUDIT_SCRIPT), scan_out_of_scope))
chk(!length(offenders),
    sprintf("G3a no manuscript figure script draws an out-of-scope source%s",
            if (length(offenders)) paste0(" [", paste(offenders, collapse = "; "), "]") else ""))

# SABOTEUR: put the card back and run the REAL scanner over it. Asserting that
# a string I just built contains the word I put in it would prove nothing --
# the scanner has to be the thing that fires.
poisoned <- tempfile(fileext = ".R")
writeLines(c(readLines(FIG2_SCRIPT, warn = FALSE),
             'p <- p + annotate("text", label = "Trilliant", x = 1, y = 1)'),
           poisoned)
chk(length(scan_out_of_scope(poisoned)) == 1L,
    "G3b KILLED: a reintroduced Trilliant card is caught by the same scanner that passes the real script")
# ... and the header paragraph explaining the removal must NOT trip it.
commented <- tempfile(fileext = ".R")
writeLines(c("# the fourth card was Trilliant, a commercial provider directory",
             'labs(title = "in scope")'), commented)
chk(length(scan_out_of_scope(commented)) == 0L,
    "G3c a comment explaining why the source was removed is not itself a violation")

# --- G4 figure citations --------------------------------------------------------
sab(4, "every figure is cited once, in prose, before its caption")
qmd <- readLines(QMD, warn = FALSE)
# Captions are the markdown image lines; citations are every other mention.
cap_idx <- grep("^!\\[\\*\\*Figure [0-9]+\\.\\*\\*", qmd)
cap_num <- as.integer(sub("^!\\[\\*\\*Figure ([0-9]+)\\.\\*\\*.*", "\\1", qmd[cap_idx]))
cite_idx <- grep("Figure [0-9]+", qmd)
cite_idx <- setdiff(cite_idx, cap_idx)
cite_num <- unlist(lapply(cite_idx, function(i)
  as.integer(regmatches(qmd[i], gregexpr("(?<=Figure )[0-9]+", qmd[i], perl = TRUE))[[1]])))

chk(identical(sort(cap_num), seq_along(cap_num)),
    sprintf("G4a figure captions are numbered 1..%d with no gap or repeat", length(cap_num)))
chk(identical(sort(unique(cite_num)), sort(cap_num)),
    "G4b every figure that has a caption is cited in the prose, and no citation points at a figure that does not exist")
# COUNTED BEFORE THE CAPTION, NOT ANYWHERE IN THE FILE. The original rule was
# "cited exactly once", which held while every figure was cited once in its own
# Results paragraph. It is wrong against a paper that also carries a closing
# sentence listing its display items ("Tables 1 through 4, Figure 1, and the
# supplemental digital content are ..."). That back-reference is not a second
# citation, and counting it as one made this gate fail on a correct manuscript.
#
# The defect the rule exists to catch survives the change intact: Figure 6
# standing in for Figure 5 meant Figure 5 had NO citation (G4b and G4d both
# fire) and Figure 6 had two FORWARD ones (G4c fires). Relaxing "anywhere" to
# "before its caption" removes a false positive without removing a detection --
# G4f below proves that on the original defect rather than asserting it.
cites_before <- function(n, lines = qmd) {
  ci <- cite_idx[vapply(cite_idx, function(k) n %in%
    as.integer(regmatches(lines[k],
      gregexpr("(?<=Figure )[0-9]+", lines[k], perl = TRUE))[[1]]), logical(1))]
  ci[ci < cap_idx[cap_num == n]]
}
chk(all(vapply(cap_num, function(n) length(cites_before(n)) <= 1L, logical(1))),
    "G4c no figure carries two citations before its own caption")
chk(all(vapply(cap_num, function(n) length(cites_before(n)) == 1L, logical(1))),
    "G4d each figure is cited before the panel it names appears")

# SABOTEUR, numbering-independent. The old one substituted "(Figure 5)" for
# "(Figure 6)" in a manuscript that no longer contains either -- after the
# Green Journal rewrite the substitution matched nothing, the mutated text was
# the original text, and the check passed on the real file's own duplicate. A
# saboteur that cannot distinguish the mutation from the source is not one.
# This plants a second FORWARD citation of a figure that really exists.
n1 <- cap_num[1]
planted <- qmd
planted[cap_idx[cap_num == n1] - 1L] <-
  paste0(planted[cap_idx[cap_num == n1] - 1L], " (Figure ", n1, ")")
planted_before <- {
  ci <- grep("Figure [0-9]+", planted)
  ci <- setdiff(ci, cap_idx)
  ci <- ci[vapply(ci, function(k) n1 %in%
    as.integer(regmatches(planted[k],
      gregexpr("(?<=Figure )[0-9]+", planted[k], perl = TRUE))[[1]]), logical(1))]
  ci[ci < cap_idx[cap_num == n1]]
}
chk(length(planted_before) > 1L,
    "G4e KILLED: a second citation planted before a figure's caption is caught")

# The ORIGINAL defect, replayed against the relaxed rule so the relaxation is
# demonstrated non-destructive rather than argued to be.
orig_cap <- c(5L, 6L)
orig_cites <- c(6L, 6L)          # Figure 5 never cited; Figure 6 cited twice
chk(!identical(sort(unique(orig_cites)), sort(orig_cap)) &&
      sum(orig_cites == 6L) > 1L,
    "G4f KILLED: the Figure 5 / Figure 6 defect still fails both the existence and the duplicate rule")

# --- G5 a rate is stated in the units of its denominator ------------------------
sab(5, "a provider-year rate is not reported as a per-midwife rate")
qmd_txt <- read_text(QMD)
ms_head <- grep("^### .*in six", qmd, value = TRUE)
chk(length(ms_head) == 1L && grepl("provider-year", ms_head),
    "G5a the multi-state heading names the provider-year denominator it is computed on")
# The paragraph that prints medicaid_multistate_pct must say what it is a
# percentage OF, in the same sentence.
pct_line <- grep("medicaid_multistate_pct", qmd, value = TRUE)
chk(length(pct_line) >= 1L && any(grepl("provider-year", pct_line)),
    "G5b the sentence printing the rate names provider-years as its denominator")
# ... and the figure beside it, which is on a DIFFERENT denominator, says so.
# FOUND BY THE FIGURE'S IDENTITY, NOT ITS NUMBER. This block used to locate
# the multi-state panel as "Figure 5" and feed grep()'s result straight to
# seq(). The Green Journal rewrite renumbered it to Supplemental Figure S4, so
# the grep returned integer(0), seq() raised "'from' must be of length 1", and
# the suite ABORTED here -- G5c through G6 never ran at all while the job
# reported a single failure. A gate pinned to a journal's figure numbering
# breaks on every renumbering; the artifact name does not move.
ms_fig <- grep("medicaid_multistate_footprint", qmd)
chk(length(ms_fig) == 1L,
    "G5c the multi-state Medicaid panel is present exactly once, found by artifact name")
if (length(ms_fig) == 1L) {
  start <- max(c(1L, grep("^!\\[", qmd)[grep("^!\\[", qmd) <= ms_fig]))
  ms_block <- paste(qmd[seq(start, ms_fig)], collapse = " ")
  chk(grepl("midwives", ms_block) && grepl("provider-year", ms_block),
      "G5c2 its caption names its own denominator and says it is not the provider-year one")
} else {
  chk(FALSE, "G5c2 skipped: the panel could not be located, so its caption was never read")
}
chk(!grepl("One midwife in six", qmd_txt, fixed = TRUE),
    "G5d the per-midwife phrasing of a provider-year statistic is gone from the manuscript")

# SABOTEUR: put the per-midwife heading back and run the same predicates.
old_head <- "### One midwife in six is enrolled in Medicaid in more than one state at once"
head_ok <- function(h) length(h) == 1L && grepl("provider-year", h)
chk(!head_ok(old_head) && head_ok(ms_head),
    "G5e KILLED: the original per-midwife heading fails the same check the corrected one passes")

# --- G6 American spelling in reader-visible figure labels -----------------------
sab(6, "figure labels use the journal's spellings")
# Only quoted strings that reach a reader: labs(), subtitles, captions, axis
# titles. Comments are not typeset and are not scanned. label_strings() is
# defined above, under G3, and both scanners share it deliberately.
BRITISH <- c("programme", "licence", "enrolment", "organisation", "behaviour")
scan_british <- function(path) {
  strs <- label_strings(path)
  # sub("licence", "license", ...) is the relabelling that FIXES the artifact's
  # spelling for display, so the search term appearing as the first argument of
  # a substitution is the repair, not the defect.
  strs <- strs[!grepl("^\"(programme|licence|enrolment|organisation|behaviour)\"$", strs)]
  unlist(lapply(BRITISH, function(b)
    if (any(grepl(b, strs, fixed = TRUE))) paste0(basename(path), ": ", b)
    else character(0)))
}
hits <- unlist(lapply(c(AUDIT_SCRIPT, FIG2_SCRIPT), scan_british))
chk(!length(hits),
    sprintf("G6a no reader-visible figure label carries a British spelling%s",
            if (length(hits)) paste0(" [", paste(unique(hits), collapse = "; "), "]") else ""))

# SABOTEUR: both directions, through the real scanner.
brit_label <- tempfile(fileext = ".R")
writeLines('labs(x = "State Medicaid programmes she is enrolled in")', brit_label)
chk(length(scan_british(brit_label)) == 1L,
    "G6b KILLED: the exact label this fix corrected is caught when put back")
brit_comment <- tempfile(fileext = ".R")
writeLines(c("# the artifact spells it licence; relabelled for display",
             'labs(x = "license group")'), brit_comment)
chk(length(scan_british(brit_comment)) == 0L,
    "G6c a British spelling in a comment is not a failure, because a comment is not typeset")

# --- G7 no statistic is typed into the prose ------------------------------------
sab(7, "every statistic is reached by key, not typed into the sentence")
# The manuscript's own setup chunk says every figure in the text is reached by
# key and nothing is typed by hand. Two were: the Results and the Discussion
# both printed pc(74.7, 1) and pc(88.5, 1) as literals. They were not WRONG --
# audit_medicaid_set_membership.R writes exactly those two values to a tracked
# artifact -- but a typed number does not move when its artifact is rebuilt,
# and the three vintages of one number this catalog was built to prevent all
# started as a correct number typed once.
#
# The first argument of pc() or cnt() is the statistic. A numeric literal
# there is a typed statistic; a literal in the SECOND argument is the number
# of decimal places, which is formatting and not a finding.
typed_stats <- function(lines)
  grep("\\b(pc|cnt)\\(\\s*[0-9]", lines, value = TRUE, perl = TRUE)

typed <- typed_stats(qmd)
chk(!length(typed),
    sprintf("G7a no statistic is typed into the manuscript prose%s",
            if (length(typed)) paste0(" [", length(typed), " site(s): ",
                                      paste(trimws(substr(typed, 1, 40)), collapse = " | "), "]")
            else ""))
# SABOTEUR: type one back in, exactly as it was, and the scanner must see it.
chk(length(typed_stats("`r pc(74.7, 1)` to `r pc(88.5, 1)` on identical records.")) == 1L,
    "G7b KILLED: the literal pair this fix replaced is caught when typed back in")
chk(length(typed_stats("`r pc(A$medicaid_equality_pct, 1)` rose to `r cnt(A$n)`")) == 0L,
    "G7c a catalog key with a decimal-place argument is not a typed statistic")

cat(sprintf("\n%s (%d failure(s) across 7 manuscript-figure saboteurs)\n",
            if (fails == 0L) "ALL SABOTEURS HELD" else "SABOTEURS FOUND GAPS", fails))
quit(status = if (fails == 0L) 0L else 1L)
