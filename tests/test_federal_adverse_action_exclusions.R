source(file.path("R", "federal_adverse_action_exclusions.R"))

stopifnot(
  "Federal adverse action: DEA Federal Register" %in%
    exclude_federal_adverse_actions(
      data.frame(npi = "1000000001", stringsAsFactors = FALSE),
      data.frame(
        npi = "1000000001",
        federal_adverse_action_excluded = TRUE,
        federal_adverse_action_source = "DEA Federal Register",
        stringsAsFactors = FALSE
      )
    )$excluded$exclusion_reason
)

flags <- build_federal_adverse_action_flags(list(
  data.frame(npi = c("1000000001", "1000000002"), listed = c("Y", "N"),
             source = "DEA Federal Register", stringsAsFactors = FALSE),
  data.frame(npi = c("1000000002", "1000000003"), listed = TRUE,
             source = "FDA", stringsAsFactors = FALSE)
))
stopifnot(
  setequal(flags$npi, c("1000000001", "1000000002", "1000000003")),
  grepl("FDA", flags$federal_adverse_action_source[flags$npi == "1000000003"])
)

cat("federal adverse-action exclusions: PASS\n")

