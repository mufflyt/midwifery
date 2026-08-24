# =============================================================================
# Science contracts: the claims the analysis is allowed to make
# =============================================================================
# ci_artifact_contracts.R checks arithmetic inside a file. ci_semantic_contracts.R
# checks that two files describe the same world. This file checks something
# neither does: that the CODE does not assert more than the DATA supports.
#
# Every gate here is a rule that was stated during the affiliation work and
# then broken, or nearly broken, in this repository. They are static checks on
# tracked source and committed artifacts -- none needs the person-level data,
# which is why they can run on a runner at all.
#
#   SCI1  Affiliation is never labelled "employer". PECOS reassignment records
#         a billing relationship; DAC records an observed association; NPPES
#         co-location records a shared address. None of the three is employment,
#         and a column named `employer` claims it is.
#
#   SCI2  Fail-closed linkage. "Resolved" means EXACTLY ONE candidate survived.
#         Narrowing a field of nine to a field of two is not resolution, and any
#         code that picks a winner from several -- first(), slice_max(),
#         "most plausible", arg-max on a plausibility score -- converts an
#         ambiguity into a fabricated fact.
#
#   SCI3  Absence-as-negative requires a data contract that licenses it. Sources
#         registered `partial` in the coverage matrix are positive-observation
#         only; treating a missing row as a "No" turns unobserved into observed.
#         This is the defect that disabled the Table 1 Medicare variable for
#         eight months.
#
#   SCI4  Author-chosen thresholds are flagged exploratory. A density cut or a
#         similarity floor picked by looking at the answer is a hypothesis, not
#         a measurement, and an artifact that does not say so reads as one.
#
#   SCI5  One address normaliser. ~/isochrones/R/address_parsing_standardized.R
#         is canonical; this repo reaches it through
#         R/lib/address_parser_canonical.R. A second private street-abbreviation
#         table produces different join keys from the same addresses, which is
#         how "3130 HIGHLAND AVENUE" and "3130 HIGHLAND AVE" became two places.
#
#   SCI6  Independent sources are not pooled into one verdict. Open Payments,
#         Healthgrades and Doximity agreed on 0 of 5 overlapping cases; a
#         majority vote across them would have manufactured agreement that the
#         sources do not contain.
#
# Base R only. Static source analysis plus committed artifacts. No network.
# =============================================================================

root <- "."
if (!dir.exists(file.path(root, ".git")) && dir.exists("../.git")) root <- ".."
source(file.path(root, "tests", "ci_report.R"))

# Code lines only. A rule NAMED in a comment or a roxygen block is documentation
# of the rule, not a violation of it -- these gates are heavily commented in the
# very files they police, and matching prose would make every gate self-tripping.
# That mistake was made three times in this repo's test suite already.
code_lines <- function(path) {
  txt <- tryCatch(readLines(file.path(root, path), warn = FALSE),
                  error = function(e) character(0))
  txt[!grepl("^\\s*#'?", txt)]
}

# Files that carry the analysis. Excludes tests/ so a gate does not police the
# fixtures written to prove the gate works.
analysis_files <- function() {
  f <- c(ci_tracked("*.R"), ci_tracked("R/*.R"), ci_tracked("R/lib/*.R"))
  unique(f[!grepl("^tests/", f)])
}

# CSV reading is ci_read_head() from ci_report.R. Not aliased to a local name:
# ci_semantic_contracts.R defines its own read_head(), and H4 counts a
# one-line delegator as a second top-level definition -- correctly, since the
# delegator is what would drift.

# -----------------------------------------------------------------------------
ci_section("SCI1 organizational affiliation is never labelled employment")

# Column ASSIGNMENTS and artifact headers, not prose. `employer` appearing in a
# sentence explaining why the word is wrong must not fail this gate.
EMPLOY <- "\\b(employer|employed_by|employment_org|works_for)\\b\\s*(=|<-)"
off <- character(0)
for (f in analysis_files()) {
  hits <- grep(EMPLOY, code_lines(f), value = TRUE)
  if (length(hits)) off <- c(off, sprintf("%s: %s", f, trimws(hits[1])))
}
arts <- ci_tracked("artifacts/*.csv")
for (a in arts) {
  h <- ci_read_head(a, 1L, root = root)
  if (is.null(h)) next
  bad <- grep("^(employer|employed_by|employment_org|works_for)$", names(h),
              ignore.case = TRUE, value = TRUE)
  if (length(bad)) off <- c(off, sprintf("%s: column `%s`", a, bad[1]))
}
if (length(off)) {
  ci_fail("SCI1: %d site(s) name an organizational affiliation as employment:\n%s\n       Use `organization_affiliation`. Reassignment, co-location and\n       directory listing are not employment relationships.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("no employment label on an affiliation variable (%d files, %d artifacts)",
        length(analysis_files()), length(arts))
}

# -----------------------------------------------------------------------------
ci_section("SCI2 fail-closed linkage: resolved means exactly one candidate")

# The signature of a tie-break: a variable whose name says resolved/matched/
# affiliation being assigned from a row-picking verb. slice_max() and
# arrange()+first() are the two forms this repo has actually used.
#
# The assigned variable must name an ORGANIZATION, not a label about one.
# `resolution_method = first(resolution_method)` carries a method string
# through a group; `primary_organization = first(organization_name)` chooses
# which employer to report. Only the second is the defect, and an earlier
# version of this pattern flagged the first while missing the second.
PICK <- paste0("\\b(primary_org|resolved_org|matched_org|one_org|assigned_org|",
               "org_name|organization_name|organization_npi|type2_npi)[a-z_0-9]*",
               "\\s*(=|<-)\\s*[^\\n]*",
               "\\b(dplyr::)?(slice_max|slice_min|slice_head|slice_sample|",
               "first|last|which\\.max|which\\.min|top_n)\\b")

# KNOWN, AWAITING A DECISION -- not forgiven.
#
# These three predate the gate and each writes a `_candidate` artifact, none of
# which is promoted into a published table. resolve_org_ambiguity.R is the
# clearest: it arranges by confidence rank then organization NAME and takes
# first(), so a two-way tie at equal confidence is broken ALPHABETICALLY and
# reported as `primary_organization`.
#
# They are baselined rather than rewritten because changing a matching policy to
# make a test pass is the wrong direction of causation -- the policy question
# belongs to the author. The baseline can only shrink: a fourth site fails this
# gate, and removing one of these three requires deleting its line here.
PICK_BASELINE <- c(
  "classify_residual_disagreements.R",
  "link_practice_locations_to_org_npi.R",
  "resolve_org_ambiguity.R"
)

# A pick GUARDED by a uniqueness test is not a pick -- it takes the ONLY
# candidate. `if (n_distinct(org_npi) == 1L) first(org_name) else NA` is
# fail-closed resolution written explicitly, and flagging it would push authors
# toward less legible code that reads the same to this gate.
GUARDED <- "(n_distinct\\([^)]*\\)|\\bn\\b|n_orgs?)\\s*==\\s*1L?\\b"

off <- character(0); known <- character(0)
for (f in analysis_files()) {
  hits <- grep(PICK, code_lines(f), value = TRUE, perl = TRUE)
  hits <- hits[!grepl(GUARDED, hits, perl = TRUE)]
  if (!length(hits)) next
  entry <- sprintf("%s: %s", f, trimws(hits[1]))
  if (f %in% PICK_BASELINE) known <- c(known, entry) else off <- c(off, entry)
}
# Only files that are STILL TRACKED can be stale. A baselined file that has
# been deleted is not "fixed", it is gone, and treating absence as a fix made
# this check fire in any repository that does not contain all three -- which is
# every scaffold the gate-of-gates builds, so the clean case failed and all
# four near-miss assertions passed vacuously.
tracked <- intersect(PICK_BASELINE, analysis_files())
stale <- setdiff(tracked, sub(":.*$", "", known))
if (length(stale)) {
  ci_fail("SCI2: %d baselined site(s) no longer violate the rule:\n%s\n       Remove them from PICK_BASELINE so the baseline keeps shrinking.",
          length(stale), paste(sprintf("       %s", stale), collapse = "\n"))
}
if (length(known)) {
  ci_skip("SCI2: %d known tie-break site(s) awaiting a policy decision:", length(known))
  for (k in known) cat(sprintf("       %s\n", k))
}
if (length(off)) {
  ci_fail("SCI2: %d site(s) resolve an affiliation by PICKING from several:\n%s\n       Several candidates is ambiguous. Filter to n == 1 and leave the\n       rest unresolved; do not select the most plausible.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("no affiliation is resolved by picking a winner from several")
}

# The positive half of this rule -- "every resolver must show a `== 1` filter"
# -- was implemented and removed. Whether a script IS a resolver is not
# reliably detectable from static source: selecting by filename caught
# build_organization_affiliation_resolver.R, which deliberately resolves
# nothing, and selecting by behaviour caught seventeen scripts that merely
# count organizations to report a total. A gate with seventeen false positives
# gets switched off, and then the twelve real gates around it go too.
#
# The negative rule above is precise and found three true positives on its
# first run. That is the enforceable half; do not re-add the other one without
# a selector that distinguishes resolving from counting.

# -----------------------------------------------------------------------------
ci_section("SCI3 absence is not evidence of absence")

# A source that cannot support absence-as-negative must not be coded to "No" or
# FALSE by an is.na()/missing branch. The coverage matrix marks these `partial`.
NEG <- paste0("is\\.na\\([^)]*\\)\\s*(~|,)\\s*[\"']?(No|NO|FALSE|0)[\"']?|",
              "replace_na\\([^)]*[\"']No[\"']|",
              "coalesce\\([^)]*,\\s*[\"']No[\"']\\)")
off <- character(0)
for (f in analysis_files()) {
  txt <- code_lines(f)
  # Only where a partial-coverage source is in play. A "No" default on a
  # complete-enumeration variable (a roster field, a state license table) is
  # legitimate and must not be flagged.
  if (!any(grepl("\\b(dac|doctors_and_clinicians|open_payments|healthgrades|doximity|endpoint)\\b",
                 txt, ignore.case = TRUE))) next
  hits <- grep(NEG, txt, value = TRUE, perl = TRUE)
  if (length(hits)) off <- c(off, sprintf("%s: %s", f, trimws(hits[1])))
}
if (length(off)) {
  ci_fail("SCI3: %d site(s) convert a missing row from a partial-coverage source into a negative:\n%s\n       These sources are positive-observation only. Absent means unobserved,\n       and the level must say so (\"Not observed\", not \"No\").",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("no partial-coverage source is coded absence-as-negative")
}

# The coverage matrix is where the partial/complete distinction is recorded. If
# it exists, it must actually carry the flag -- otherwise SCI3's premise is gone.
cm <- "artifacts/affiliation_coverage_matrix.csv"
if (!file.exists(file.path(root, cm))) {
  ci_skip("%s absent (gitignored or not yet built); flag check skipped", cm)
} else {
  h <- ci_read_head(cm, 1L, root = root)
  # The distinction is carried as `any_strong_arm`: the arms registry marks
  # partial sources, and the artifact records whether any NON-partial arm saw
  # the midwife. That is the same information in the form the artifact needs --
  # a per-row `partial` column would be constant per arm, not per midwife.
  FLAG <- "^(partial|any_strong_arm)$"
  if (is.null(h) || !any(grepl(FLAG, names(h), ignore.case = TRUE))) {
    ci_fail("SCI3b: %s records no partial/strong arm distinction.\n       Without it nothing says which arms may be read as absence.", cm)
  } else {
    ci_ok("%s records the partial/strong arm distinction", cm)
  }
}

# -----------------------------------------------------------------------------
ci_section("SCI4 author-chosen thresholds are declared exploratory")

# Artifacts produced by an experiment_* script carry a threshold nobody
# pre-registered. They must say so in the file, because a reader cannot tell a
# measured quantity from a tuned one by looking at the number.
exps <- ci_tracked("experiment_*.R")
if (!length(exps)) {
  ci_skip("no experiment_* scripts tracked; skipped")
} else {
  # Only experiments that actually CHOOSE a cut need the flag. Exact-key
  # experiments -- endpoint affiliation, secondary practice location -- have no
  # tunable parameter, and demanding an `exploratory` column from them would
  # mark a measurement as a hypothesis.
  CUT <- paste0("(threshold|cutoff|min_[a-z_]+|_floor)\\s*(=|<-)\\s*[0-9]|",
                "\\bfilter\\([^)]*\\b(n_clin|density|similarity|score)[a-z_]*",
                "\\s*(>=|>|<=|<)\\s*[0-9]")
  tuned <- Filter(function(f) any(grepl(CUT, code_lines(f), perl = TRUE)), exps)
  if (!length(tuned)) {
    ci_skip("no experiment script chooses a numeric cut; nothing to declare")
  }
  off <- tuned[!vapply(tuned,
                       function(f) any(grepl("exploratory", code_lines(f))),
                       logical(1))]
  if (length(off)) {
    ci_fail("SCI4: %d experiment script(s) never mark a row exploratory:\n%s\n       A threshold chosen after seeing the data is a hypothesis. Set\n       exploratory = TRUE on the rows it produces.",
            length(off), paste(sprintf("       %s", off), collapse = "\n"))
  } else {
    ci_ok("all %d experiment scripts declare exploratory rows", length(exps))
  }
}

# -----------------------------------------------------------------------------
ci_section("SCI5 one address normaliser")

# The canonical parser lives in ~/isochrones and is reached through this
# delegating wrapper. The wrapper must exist and must contain no parsing table
# of its own -- a delegator that grows a fallback is a second parser again.
WRAP <- "R/lib/address_parser_canonical.R"
if (!file.exists(file.path(root, WRAP))) {
  ci_fail("SCI5: %s is missing.\n       Without it every caller reimplements street abbreviation privately.", WRAP)
} else {
  w <- code_lines(WRAP)
  # A street-suffix mapping inside the delegator. The canonical parser owns
  # these; a copy here is the fork this gate exists to prevent.
  SUFFIX <- "\\bAVENUE\\b|\\bBOULEVARD\\b|\\bPARKWAY\\b|\\bSTREET\\b\\s*[\"']?\\s*,"
  if (any(grepl(SUFFIX, w))) {
    ci_fail("SCI5: %s contains a street-suffix table.\n       It must delegate to the isochrones parser, not reimplement it.", WRAP)
  } else if (!any(grepl("(parse|normalize)_addresses_canonical", w))) {
    # EITHER canonical entry point counts. The wrapper was moved from
    # normalize_addresses_canonical() -- marked deprecated upstream -- to
    # parse_addresses_canonical(), and this check named only the old one, so it
    # reported a correctly-delegating wrapper as delegating to nothing. The rule
    # is "calls the canonical parser", not "calls one particular function of it".
    ci_fail("SCI5: %s calls neither parse_addresses_canonical() nor normalize_addresses_canonical().\n       It is not delegating to anything.", WRAP)
  } else {
    ci_ok("%s delegates to the canonical parser and holds no suffix table", WRAP)
  }
}

# New callers must not start a THIRD table. The two legacy functions in
# address_keys.R are grandfathered by name and counted, so the number can only
# go down.
LEGACY <- c("norm_addr", "norm_addr_drop_unit")
# norm_addr_canonical_keep_unit is sanctioned deliberately, not grandfathered.
# Swapping in the canonical parser wholesale bundles a POLICY change with a
# normalisation fix -- it DISCARDS suites, which norm_addr() keeps because two
# suites in one building are two workplaces. That variant isolates the
# normalisation half so the policy can be decided separately. It delegates to
# norm_addr_canonical() and holds no street-suffix table of its own.
defs <- character(0)
for (f in analysis_files()) {
  d <- grep("^\\s*(norm_addr[a-z_]*|normali[sz]e_addr[a-z_]*)\\s*<-\\s*function",
            code_lines(f), value = TRUE)
  if (length(d)) defs <- c(defs, sprintf("%s: %s", f, trimws(d)))
}
extra <- defs[!grepl(sprintf("\\b(%s|norm_addr_canonical|norm_addr_canonical_keep_unit)\\s*<-",
                             paste(LEGACY, collapse = "|")), defs)]
if (length(extra)) {
  ci_fail("SCI5b: %d address normaliser(s) defined outside the sanctioned set:\n%s\n       Sanctioned: %s (legacy) and norm_addr_canonical (delegating).",
          length(extra), paste(sprintf("       %s", extra), collapse = "\n"),
          paste(LEGACY, collapse = ", "))
} else {
  ci_ok("%d address normaliser definition(s), all sanctioned", length(defs))
}

# -----------------------------------------------------------------------------
ci_section("SCI6 independent sources are not pooled into one verdict")

# Cross-source majority voting. Open Payments, Healthgrades and Doximity agreed
# on 0 of 5 overlapping cases; a vote across them would have produced a verdict
# none of them supports.
#
# `vote` must not match `voter`. calibrate_amcb_certification_ages.R holds
# `fl_voter_path <- "artifacts/florida_voter_license_ages.csv"` -- a Florida
# voter file, which is a data source, not a ballot among directories.
VOTE <- paste0("\\b(majority|consensus|vote|votes|voting)\\s*(=|<-)|",
               "\\bsum\\(\\s*(agree|concur)[a-z_]*\\s*\\)\\s*(>=|>)\\s*[0-9]")
off <- character(0)
for (f in analysis_files()) {
  txt <- code_lines(f)
  if (!any(grepl("open_payments", txt) & TRUE) &&
      !any(grepl("healthgrades|doximity", txt, ignore.case = TRUE))) next
  hits <- grep(VOTE, txt, value = TRUE, perl = TRUE)
  if (length(hits)) off <- c(off, sprintf("%s: %s", f, trimws(hits[1])))
}
if (length(off)) {
  ci_fail("SCI6: %d site(s) pool independent external sources into one verdict:\n%s\n       Report each source separately. A disagreement between two commercial\n       directories is a finding, not noise to average away.",
          length(off), paste(sprintf("       %s", off), collapse = "\n"))
} else {
  ci_ok("external sources are reported separately, never pooled")
}

ci_finish()
