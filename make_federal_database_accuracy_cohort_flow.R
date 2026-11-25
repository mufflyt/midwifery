#!/usr/bin/env Rscript

source(file.path("R", "lib", "artifact_provenance.R"))
source(file.path("R", "lib", "cohort_definitions.R"))   # verify_linkage_freeze()

summary_path <- "artifacts/linkage_completeness_by_status.csv"
frozen_path <- "artifacts/amcb_npi_linkage_FROZEN.csv"
s <- read.csv(summary_path, stringsAsFactors = FALSE)
verify_linkage_freeze(frozen_path)
f <- read.csv(frozen_path, stringsAsFactors = FALSE, colClasses = "character")

sum_col <- function(x) sum(as.numeric(s[[x]]), na.rm = TRUE)
counts <- c(
  amcb_records = sum_col("n"),
  midwifery_taxonomy = sum_col("matched"),
  nursing_taxonomy = sum_col("matched_nursing_taxonomy"),
  no_candidate = sum_col("unmatched"),
  ambiguous_tied_names = sum_col("ambiguous_tied_names"),
  contested_npi = sum_col("ambiguous_contested_npi"),
  unresolved_component = sum_col("ambiguous_unruled_out_component"),
  held_out_candidate = sum_col("candidate_class5_held_out_of_cohort")
)
counts <- c(counts, analytic_cohort = unname(counts["midwifery_taxonomy"] + counts["nursing_taxonomy"]))

stopifnot(sum(counts[c("midwifery_taxonomy", "nursing_taxonomy", "no_candidate",
                       "ambiguous_tied_names", "contested_npi",
                       "unresolved_component", "held_out_candidate")]) == counts["amcb_records"])
cohort <- f[f$cohort_member == "TRUE", , drop = FALSE]
stopifnot(nrow(cohort) == counts["analytic_cohort"],
          length(unique(cohort$npi[nzchar(cohort$npi)])) == counts["analytic_cohort"])

labels <- c(
  amcb_records = "AMCB certification records",
  midwifery_taxonomy = "Midwifery-taxonomy link",
  nursing_taxonomy = "Nursing-taxonomy sensitivity addition",
  analytic_cohort = "Analytic cohort (unique NPIs)",
  no_candidate = "No candidate NPI",
  ambiguous_tied_names = "Tied name evidence",
  contested_npi = "NPI claimed by\nmultiple certificants",
  unresolved_component = "Candidate component\nunresolved",
  held_out_candidate = "Candidate held out\nby linkage rule"
)
flow <- data.frame(stage = names(counts), label = unname(labels[names(counts)]),
                   n = as.integer(counts), unit = "certification record",
                   stringsAsFactors = FALSE)
flow$unit[flow$stage == "analytic_cohort"] <- "unique NPI"
flow$parent <- ifelse(flow$stage == "amcb_records", "",
                      ifelse(flow$stage == "analytic_cohort", "included_tiers", "amcb_records"))

write_with_provenance(flow, "artifacts/federal_database_accuracy_cohort_flow.csv",
                      inputs = c(summary_path, frozen_path))

png("docs/figures/federal_database_accuracy_cohort_flow.png",
    width = 1800, height = 1200, res = 220)
par(mar = c(1, 1, 2, 1), xpd = NA)
plot.new(); plot.window(c(0, 1), c(0, 1))
box <- function(x, y, w, h, text, fill = "white", cex = .72) {
  rect(x-w/2, y-h/2, x+w/2, y+h/2, col = fill, border = "#245f5b", lwd = 1.5)
  text(x, y, text, cex = cex)
}
arr <- function(x0, y0, x1, y1) arrows(x0, y0, x1, y1, length = .07, col = "#245f5b", lwd = 1.4)
fmt <- function(stage) sprintf("%s\n%s", labels[stage], format(counts[stage], big.mark = ","))
box(.5, .91, .36, .10, fmt("amcb_records"), "#e7f0ef")
box(.18, .70, .29, .11, fmt("midwifery_taxonomy"))
box(.50, .70, .31, .11, fmt("nursing_taxonomy"))
excluded_total <- counts["amcb_records"] - counts["analytic_cohort"]
box(.82, .70, .25, .11,
    sprintf("Outside analytic cohort\n%s", format(excluded_total, big.mark = ",")), "#f7f7f7")
box(.34, .48, .36, .11, fmt("analytic_cohort"), "#e7f0ef")
arr(.42,.86,.21,.76); arr(.50,.86,.50,.76); arr(.58,.86,.79,.76)
arr(.18,.64,.29,.54); arr(.50,.64,.39,.54)

excluded <- c("no_candidate", "ambiguous_tied_names", "contested_npi",
              "unresolved_component", "held_out_candidate")
xs <- seq(.10, .90, length.out = length(excluded))
for (i in seq_along(excluded)) {
  box(xs[i], .22, .18, .13, fmt(excluded[i]), "#f7f7f7", .54)
  arr(.82, .64, xs[i], .29)
}
text(.5, .055,
     "Excluded branches are mutually exclusive. Manual adjudication was not stored as a separate disposition.",
     cex = .62, col = "#555555")
dev.off()
