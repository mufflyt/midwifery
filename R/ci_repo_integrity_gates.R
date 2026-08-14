# R/ci_repo_integrity_gates.R
#
# Repository integrity gates. Each one exists because the corresponding failure
# actually happened, most of them on 2026-08-14:
#
#   absolute paths      cycle6 read /tmp/c6_attrs.csv and passed locally off a
#                       stale file; CI had no such file and went red.
#   package closure     R/join_safety.R requires checkmate at source() time. A
#                       fresh-clone check proved no missing FILE and said
#                       nothing about a missing PACKAGE. CI went red on it.
#   vacuous suites      test_healthgrades_integrity.R passes while skipping
#                       every case. A green tick that asserts nothing reads as
#                       coverage and is worse than no test.
#   vendored drift      R/safe_divide.R is described as vendored from
#                       mufflyaccess. The copies had drifted 181 lines, and the
#                       one guard on it compared a single signature line, so it
#                       stayed green throughout.
#   commit identifiers  a commit titled "Add spotlight profile for CNM <name>
#                       (NPI 1306048970, ...)" put a named person and their NPI
#                       in history metadata, where the leak guard cannot see it
#                       and untracking a file cannot remove it.
#   missing inputs      data/ct_legacy_to_region_weights.csv was untracked;
#                       cycle4 then fell back to the Census API and failed on
#                       CENSUS_API_KEY, naming the wrong cause.
#   access dates        the HPSA shapefile's vintage is unrecoverable because
#                       no download date was ever recorded.
#   safe_percent        default = 0 turns a missing denominator into "0%", the
#                       documented hazard behind three retracted figures.
#
# No system(), no system2(), no git CLI.
#
# KNOWN COVERAGE LIMIT, stated because a gate that is trusted beyond its reach
# is worse than no gate. The missing-input check sees two forms:
#
#   read_csv("data/x.csv")                     literal argument
#   PATH <- file.path("data", "x.csv")         all-literal construction
#
# It does NOT see file.path(DATA_DIR, "x.csv"), where the directory is a
# variable -- data/rucc_2023.xlsx is read that way and its deletion is not
# detected. Resolving the variable would mean guessing which directory it holds,
# and a guess here produces false findings on every output path in the repo.
# Prefer an all-literal path for anything the repository is supposed to contain.

repo_gate_log <- function(...) {
  base::message(
    "[repo-integrity] ",
    base::paste0(..., collapse = "")
  )
}


repo_gate_normalize <- function(path, root) {
  root_abs <- fs::path_abs(root)
  path_abs <- fs::path_abs(path, start = root_abs)

  fs::path_norm(path_abs)
}


# Vectorised deliberately: it is called on a whole column in
# repo_gate_check_missing_inputs(), and `||` on a length > 1 argument is an
# error in R >= 4.3 rather than a silent first-element comparison.
repo_gate_is_inside <- function(path, root) {
  if (base::length(path) == 0L) {
    return(base::logical())
  }

  path_abs <- repo_gate_normalize(path, root)
  root_abs <- fs::path_norm(fs::path_abs(root))

  base::startsWith(
    base::paste0(path_abs, "/"),
    base::paste0(root_abs, "/")
  ) |
    (path_abs == root_abs)
}


repo_gate_r_files <- function(root, ignored = character()) {
  repo_gate_log("Finding R files under ", root)

  paths <- fs::dir_ls(
    root,
    recurse = TRUE,
    type = "file",
    regexp = "\\.[Rr]$"
  )

  ignored <- base::c(
    "/\\.git/",
    "/renv/library/",
    "/\\.Rproj\\.user/",
    "/packrat/",
    ignored
  )

  keep <- !purrr::map_lgl(
    paths,
    function(path) {
      base::any(
        stringr::str_detect(
          base::paste0("/", path),
          ignored
        )
      )
    }
  )

  paths <- paths[keep]

  repo_gate_log(
    "Found ",
    scales::comma(base::length(paths)),
    " R files"
  )

  paths
}


repo_gate_parse_file <- function(path) {
  tryCatch(
    base::parse(path, keep.source = TRUE),
    error = function(err) {
      base::stop(
        "Could not parse ",
        path,
        ": ",
        base::conditionMessage(err),
        call. = FALSE
      )
    }
  )
}


repo_gate_walk_calls <- function(expr, callback) {
  if (base::is.call(expr)) {
    callback(expr)
  }

  if (base::is.recursive(expr)) {
    purrr::walk(
      base::as.list(expr),
      function(child) {
        repo_gate_walk_calls(child, callback)
      }
    )
  }

  base::invisible(NULL)
}


repo_gate_call_name <- function(call) {
  if (!base::is.call(call)) {
    return(NA_character_)
  }

  head <- call[[1L]]

  if (base::is.symbol(head)) {
    return(base::as.character(head))
  }

  if (
    base::is.call(head) &&
      base::length(head) >= 3L &&
      base::as.character(head[[1L]]) %in% base::c("::", ":::")
  ) {
    pkg <- base::as.character(head[[2L]])
    fun <- base::as.character(head[[3L]])

    return(base::paste0(pkg, "::", fun))
  }

  NA_character_
}


repo_gate_literal_string <- function(expr) {
  if (base::is.character(expr) && base::length(expr) == 1L) {
    return(expr)
  }

  NA_character_
}


# `exclude` is matched against the FILE PATH, `allow` against the line text.
# The distinction matters: a checker that stores the forbidden patterns as data
# matches itself, and no line-level allowance can express "this whole file is
# the checker".
repo_gate_find_absolute_paths <- function(
  root,
  allow = character(),
  exclude = character()
) {
  repo_gate_log("Checking R code for non-hermetic absolute paths")

  paths <- repo_gate_r_files(root, ignored = exclude)

  forbidden_pattern <- base::paste(
    base::c(
      '"/tmp/',
      "'/tmp/",
      '"/private/tmp/',
      "'/private/tmp/",
      '"/Users/',
      "'/Users/",
      '"~/',
      "'~/"
    ),
    collapse = "|",
    sep = ""
  )

  findings <- purrr::map_dfr(
    paths,
    function(path) {
      lines <- readr::read_lines(path, progress = FALSE)

      matched <- stringr::str_detect(
        lines,
        forbidden_pattern
      )

      # A comment describing the hazard is not the hazard. Only code counts.
      matched <- matched &
        !stringr::str_detect(lines, "^\\s*#")

      if (base::length(allow) > 0L) {
        matched <- matched &
          !purrr::map_lgl(
            lines,
            function(line) {
              base::any(stringr::str_detect(line, allow))
            }
          )
      }

      if (!base::any(matched)) {
        return(tibble::tibble())
      }

      tibble::tibble(
        file = base::as.character(path),
        line = base::which(matched),
        text = stringr::str_trim(lines[matched])
      )
    }
  )

  repo_gate_log(
    "Absolute-path findings: ",
    scales::comma(base::nrow(findings))
  )

  findings
}


# Resolves both source("lit.R") and source(file.path(root, "R", "lit.R")).
#
# The second form is why the package gate exists at all: R/join_safety.R is
# reached that way, and a grep for quoted ".R" strings never finds it. When the
# leading component is a symbol rather than a literal, the literal tail is
# treated as repository-relative, which is what every caller in this repo means
# by it.
repo_gate_source_targets <- function(path, root) {
  parsed <- repo_gate_parse_file(path)
  targets <- base::character()

  callback <- function(call) {
    call_name <- repo_gate_call_name(call)

    if (!call_name %in% base::c("source", "base::source")) {
      return(base::invisible(NULL))
    }

    if (base::length(call) < 2L) {
      return(base::invisible(NULL))
    }

    arg <- call[[2L]]

    if (base::is.character(arg)) {
      targets <<- base::c(
        targets,
        repo_gate_normalize(arg, root)
      )

      return(base::invisible(NULL))
    }

    if (
      base::is.call(arg) &&
        repo_gate_call_name(arg) %in%
          base::c("file.path", "base::file.path")
    ) {
      pieces <- purrr::map_chr(
        base::as.list(arg)[-1L],
        repo_gate_literal_string
      )

      literal_tail <- pieces[
        base::cumsum(base::is.na(pieces)) ==
          base::sum(base::is.na(pieces))
      ]
      literal_tail <- literal_tail[!base::is.na(literal_tail)]

      if (base::length(literal_tail) > 0L) {
        targets <<- base::c(
          targets,
          repo_gate_normalize(
            base::do.call(fs::path, base::as.list(literal_tail)),
            root
          )
        )
      }
    }

    base::invisible(NULL)
  }

  purrr::walk(
    parsed,
    function(expr) {
      repo_gate_walk_calls(expr, callback)
    }
  )

  base::unique(targets)
}


repo_gate_source_closure <- function(entrypoints, root) {
  repo_gate_log("Building source() dependency closure")

  root_abs <- fs::path_abs(root)

  pending <- purrr::map_chr(
    entrypoints,
    repo_gate_normalize,
    root = root
  )

  visited <- base::character()

  while (base::length(pending) > 0L) {
    current <- pending[[1L]]
    pending <- pending[-1L]

    if (current %in% visited) {
      next
    }

    if (!repo_gate_is_inside(current, root_abs)) {
      base::stop(
        "source() escapes repository: ",
        current,
        call. = FALSE
      )
    }

    if (!fs::file_exists(current)) {
      base::stop(
        "Missing source() target: ",
        current,
        call. = FALSE
      )
    }

    visited <- base::c(visited, current)

    children <- repo_gate_source_targets(
      current,
      root
    )

    pending <- base::unique(
      base::c(pending, children)
    )
  }

  repo_gate_log(
    "Source closure contains ",
    scales::comma(base::length(visited)),
    " files"
  )

  visited
}


repo_gate_packages_in_file <- function(path) {
  parsed <- repo_gate_parse_file(path)
  packages <- base::character()

  callback <- function(call) {
    call_name <- repo_gate_call_name(call)

    if (
      call_name %in%
        base::c(
          "library",
          "base::library",
          "require",
          "base::require",
          "requireNamespace",
          "base::requireNamespace"
        ) &&
        base::length(call) >= 2L
    ) {
      pkg_expr <- call[[2L]]

      if (base::is.symbol(pkg_expr)) {
        packages <<- base::c(
          packages,
          base::as.character(pkg_expr)
        )
      }

      if (base::is.character(pkg_expr)) {
        packages <<- base::c(
          packages,
          pkg_expr
        )
      }
    }

    head <- call[[1L]]

    if (
      base::is.call(head) &&
        base::length(head) >= 3L &&
        base::as.character(head[[1L]]) %in%
          base::c("::", ":::")
    ) {
      packages <<- base::c(
        packages,
        base::as.character(head[[2L]])
      )
    }

    base::invisible(NULL)
  }

  purrr::walk(
    parsed,
    function(expr) {
      repo_gate_walk_calls(expr, callback)
    }
  )

  base::unique(packages)
}


repo_gate_check_packages <- function(
  entrypoints,
  installed_packages,
  root
) {
  repo_gate_log("Checking packages reachable from CI test entrypoints")

  closure <- repo_gate_source_closure(
    entrypoints = entrypoints,
    root = root
  )

  package_tbl <- purrr::map_dfr(
    closure,
    function(path) {
      packages <- repo_gate_packages_in_file(path)

      if (base::length(packages) == 0L) {
        return(tibble::tibble())
      }

      tibble::tibble(
        file = path,
        package = packages
      )
    }
  )

  if (base::nrow(package_tbl) == 0L) {
    return(tibble::tibble())
  }

  base_packages <- base::c(
    "base",
    "compiler",
    "datasets",
    "graphics",
    "grDevices",
    "grid",
    "methods",
    "parallel",
    "splines",
    "stats",
    "stats4",
    "tcltk",
    "tools",
    "utils"
  )

  missing_tbl <- package_tbl |>
    dplyr::filter(
      !.data$package %in%
        base::c(installed_packages, base_packages)
    ) |>
    dplyr::distinct(.data$file, .data$package)

  repo_gate_log(
    "Unlisted reachable packages: ",
    scales::comma(base::nrow(missing_tbl))
  )

  missing_tbl
}


# `chk(` is this repository's own assertion helper. Without it every
# hand-rolled suite in tests/ looks vacuous, which would make the gate fire on
# roughly forty passing files and be switched off within a week.
repo_gate_count_test_assertions <- function(
  path,
  extra_patterns = character()
) {
  lines <- readr::read_lines(path, progress = FALSE)

  assertion_pattern <- base::paste0(
    "\\b(",
    base::paste(
      base::c(
        "expect_[A-Za-z0-9_]+",
        "assert_that",
        "stopifnot",
        extra_patterns
      ),
      collapse = "|"
    ),
    ")\\s*\\("
  )

  base::sum(
    stringr::str_detect(
      lines,
      assertion_pattern
    )
  )
}


repo_gate_check_vacuous_tests <- function(
  entrypoints,
  root,
  extra_patterns = character()
) {
  repo_gate_log("Checking CI suites for vacuous green tests")

  closure <- repo_gate_source_closure(
    entrypoints = entrypoints,
    root = root
  )

  test_files <- closure[
    stringr::str_detect(
      fs::path_file(closure),
      "^test|_test|spec"
    )
  ]

  if (base::length(test_files) == 0L) {
    return(tibble::tibble())
  }

  findings <- purrr::map_dfr(
    test_files,
    function(path) {
      count <- repo_gate_count_test_assertions(
        path,
        extra_patterns = extra_patterns
      )

      tibble::tibble(
        file = path,
        assertion_count = count
      )
    }
  ) |>
    dplyr::filter(.data$assertion_count == 0L)

  repo_gate_log(
    "Potential vacuous suites: ",
    scales::comma(base::nrow(findings))
  )

  findings
}


# Byte-for-byte on purpose. If two files are genuinely copies, 181 lines of
# divergence must be impossible to green-light; if they are meant to differ,
# they should stop being described and tested as vendored copies.
repo_gate_compare_vendored_files <- function(
  canonical_path,
  vendored_path,
  root
) {
  repo_gate_log(
    "Comparing canonical file ",
    canonical_path,
    " against vendored copy ",
    vendored_path
  )

  canonical_abs <- repo_gate_normalize(
    canonical_path,
    root
  )

  vendored_abs <- repo_gate_normalize(
    vendored_path,
    root
  )

  if (!fs::file_exists(canonical_abs)) {
    base::stop(
      "Canonical file missing: ",
      canonical_abs,
      call. = FALSE
    )
  }

  if (!fs::file_exists(vendored_abs)) {
    base::stop(
      "Vendored file missing: ",
      vendored_abs,
      call. = FALSE
    )
  }

  canonical_md5 <- base::unname(
    tools::md5sum(canonical_abs)
  )

  vendored_md5 <- base::unname(
    tools::md5sum(vendored_abs)
  )

  same <- base::identical(
    canonical_md5,
    vendored_md5
  )

  tibble::tibble(
    canonical = canonical_path,
    vendored = vendored_path,
    identical = same,
    canonical_md5 = canonical_md5,
    vendored_md5 = vendored_md5
  )
}


repo_gate_commit_messages <- function(root) {
  repo_gate_log("Reading commit messages without invoking git")

  messages <- base::character()

  event_path <- base::Sys.getenv(
    "GITHUB_EVENT_PATH",
    unset = ""
  )

  if (
    base::nzchar(event_path) &&
      fs::file_exists(event_path)
  ) {
    event <- jsonlite::fromJSON(
      event_path,
      simplifyVector = FALSE
    )

    if (!base::is.null(event$head_commit$message)) {
      messages <- base::c(
        messages,
        event$head_commit$message
      )
    }

    if (
      !base::is.null(event$commits) &&
        base::length(event$commits) > 0L
    ) {
      commit_messages <- purrr::map_chr(
        event$commits,
        function(commit) {
          commit$message %||% ""
        }
      )

      messages <- base::c(
        messages,
        commit_messages
      )
    }

    pull_title <- event$pull_request$title %||% ""
    pull_body <- event$pull_request$body %||% ""

    messages <- base::c(
      messages,
      pull_title,
      pull_body
    )
  }

  edit_path <- fs::path(
    root,
    ".git",
    "COMMIT_EDITMSG"
  )

  if (fs::file_exists(edit_path)) {
    edit_message <- base::paste(
      readr::read_lines(
        edit_path,
        progress = FALSE
      ),
      collapse = "\n"
    )

    messages <- base::c(
      messages,
      edit_message
    )
  }

  messages <- messages[
    base::nzchar(messages)
  ]

  repo_gate_log(
    "Commit/PR messages available: ",
    base::length(messages)
  )

  base::unique(messages)
}


`%||%` <- function(x, y) {
  if (base::is.null(x)) {
    return(y)
  }

  x
}


repo_gate_scan_identifiers <- function(root) {
  repo_gate_log("Scanning commit metadata for patient/provider identifiers")

  messages <- repo_gate_commit_messages(root)

  if (base::length(messages) == 0L) {
    return(tibble::tibble())
  }

  npi_pattern <- "(?<![0-9])[0-9]{10}(?![0-9])"

  findings <- purrr::map_dfr(
    base::seq_along(messages),
    function(index) {
      matches <- stringr::str_extract_all(
        messages[[index]],
        npi_pattern
      )[[1L]]

      if (base::length(matches) == 0L) {
        return(tibble::tibble())
      }

      tibble::tibble(
        message_index = index,
        identifier_type = "possible_npi",
        identifier = matches
      )
    }
  )

  repo_gate_log(
    "Commit metadata identifiers found: ",
    scales::comma(base::nrow(findings))
  )

  findings
}


# Literal-first-argument scanning is not enough. The regression this gate was
# written for looks like
#
#   CT_WEIGHTS <- file.path("data", "ct_legacy_to_region_weights.csv")
#
# assigned once and read later through the variable, so the read call has no
# literal to inspect. Any all-literal path construction pointing into an input
# directory is therefore treated as a declared input, wherever it appears.
#
# Scoped to `input_dirs` (data/ by default) on purpose: an all-literal path
# anywhere would sweep up every OUTPUT the pipeline writes and report each as a
# missing input.
repo_gate_declared_input_paths <- function(path, root, input_dirs = "data") {
  parsed <- repo_gate_parse_file(path)
  discovered <- base::character()

  data_ext <- "\\.(csv|tsv|txt|xlsx|xls|rds|parquet|json|dbf|shp|zip|duckdb)$"

  callback <- function(call) {
    if (
      !repo_gate_call_name(call) %in%
        base::c("file.path", "base::file.path")
    ) {
      return(base::invisible(NULL))
    }

    pieces <- purrr::map_chr(
      base::as.list(call)[-1L],
      repo_gate_literal_string
    )

    if (base::anyNA(pieces) || base::length(pieces) == 0L) {
      return(base::invisible(NULL))
    }

    rel <- base::paste(pieces, collapse = "/")

    inside <- base::any(
      stringr::str_starts(rel, base::paste0(input_dirs, "/"))
    )

    if (!inside || !stringr::str_detect(rel, data_ext)) {
      return(base::invisible(NULL))
    }

    discovered <<- base::c(
      discovered,
      repo_gate_normalize(rel, root)
    )

    base::invisible(NULL)
  }

  purrr::walk(
    parsed,
    function(expr) {
      repo_gate_walk_calls(expr, callback)
    }
  )

  base::unique(discovered)
}


repo_gate_literal_input_paths <- function(path, root) {
  parsed <- repo_gate_parse_file(path)
  discovered <- base::character()

  input_functions <- base::c(
    "read.csv",
    "utils::read.csv",
    "readRDS",
    "base::readRDS",
    "readLines",
    "base::readLines",
    "read_csv",
    "readr::read_csv",
    "readr::read_csv2",
    "readr::read_delim",
    "readr::read_tsv",
    "arrow::read_parquet",
    "arrow::read_feather",
    "qs::qread"
  )

  callback <- function(call) {
    call_name <- repo_gate_call_name(call)

    if (!call_name %in% input_functions) {
      return(base::invisible(NULL))
    }

    if (base::length(call) < 2L) {
      return(base::invisible(NULL))
    }

    literal <- repo_gate_literal_string(
      call[[2L]]
    )

    if (base::is.na(literal)) {
      return(base::invisible(NULL))
    }

    if (
      stringr::str_detect(
        literal,
        "^(https?|s3|gs|ftp)://"
      )
    ) {
      return(base::invisible(NULL))
    }

    discovered <<- base::c(
      discovered,
      repo_gate_normalize(
        literal,
        root
      )
    )

    base::invisible(NULL)
  }

  purrr::walk(
    parsed,
    function(expr) {
      repo_gate_walk_calls(expr, callback)
    }
  )

  base::unique(discovered)
}



# A missing input is only a defect if the repository is supposed to contain it.
# Person-level artifacts and multi-gigabyte inputs are gitignored BY DESIGN and
# absent from every clone, so without this the gate reports 68 findings in CI
# and none locally -- the exact working-tree-versus-runner inversion these gates
# exist to stop.
#
# Reads .gitignore directly. The git CLI is deliberately not used, so this is a
# deliberately modest matcher: literal paths, leading-slash anchors, trailing
# slash directories, and `*` within a segment. It is allowed to under-match --
# an unmatched pattern means a finding a human then reads, which is the safe
# direction.
repo_gate_ignore_matchers <- function(root) {
  path <- fs::path(root, ".gitignore")

  if (!fs::file_exists(path)) {
    return(base::character())
  }

  lines <- readr::read_lines(path, progress = FALSE)
  lines <- stringr::str_trim(lines)
  lines <- lines[base::nzchar(lines)]
  lines <- lines[!stringr::str_starts(lines, "#")]
  lines <- lines[!stringr::str_starts(lines, "!")]

  purrr::map_chr(
    lines,
    function(pattern) {
      anchored <- stringr::str_starts(pattern, "/")
      is_dir <- stringr::str_ends(pattern, "/")

      body <- stringr::str_remove(pattern, "^/")
      body <- stringr::str_remove(body, "/$")

      body <- stringr::str_replace_all(
        body,
        "([.\\\\+^$(){}\\[\\]|])",
        "\\\\\\1"
      )
      body <- stringr::str_replace_all(body, stringr::fixed("**"), "\u0001")
      body <- stringr::str_replace_all(body, stringr::fixed("*"), "[^/]*")
      body <- stringr::str_replace_all(body, stringr::fixed("\u0001"), ".*")

      base::paste0(
        if (anchored) "^" else "(^|/)",
        body,
        if (is_dir) "(/|$)" else "(/|$)"
      )
    }
  )
}


repo_gate_is_ignored <- function(rel_paths, matchers) {
  if (base::length(matchers) == 0L || base::length(rel_paths) == 0L) {
    return(base::rep(FALSE, base::length(rel_paths)))
  }

  purrr::map_lgl(
    rel_paths,
    function(rel) {
      base::any(stringr::str_detect(rel, matchers))
    }
  )
}

repo_gate_check_missing_inputs <- function(
  root,
  ignored = character(),
  baseline = character()
) {
  repo_gate_log("Checking literal repository inputs exist")

  paths <- repo_gate_r_files(root, ignored = ignored)

  input_tbl <- purrr::map_dfr(
    paths,
    function(path) {
      inputs <- base::unique(base::c(
        repo_gate_literal_input_paths(path, root),
        repo_gate_declared_input_paths(path, root)
      ))

      if (base::length(inputs) == 0L) {
        return(tibble::tibble())
      }

      tibble::tibble(
        source_file = base::as.character(path),
        input_path = inputs
      )
    }
  )

  if (base::nrow(input_tbl) == 0L) {
    return(tibble::tibble())
  }

  findings <- input_tbl |>
    dplyr::filter(
      repo_gate_is_inside(.data$input_path, root)
    ) |>
    dplyr::mutate(
      input_rel = base::as.character(
        fs::path_rel(.data$input_path, root)
      ),
      exists = fs::file_exists(.data$input_path)
    ) |>
    dplyr::filter(!.data$exists) |>
    dplyr::filter(!.data$input_rel %in% baseline)

  if (base::nrow(findings) > 0L) {
    matchers <- repo_gate_ignore_matchers(root)

    findings <- findings |>
      dplyr::filter(
        !repo_gate_is_ignored(.data$input_rel, matchers)
      )
  }

  repo_gate_log(
    "Missing literal inputs: ",
    scales::comma(base::nrow(findings))
  )

  findings
}


repo_gate_find_artifact_files <- function(root) {
  artifact_dir <- fs::path(
    root,
    "artifacts"
  )

  if (!fs::dir_exists(artifact_dir)) {
    return(base::character())
  }

  fs::dir_ls(
    artifact_dir,
    recurse = TRUE,
    type = "file"
  )
}


repo_gate_sidecar_candidates <- function(path) {
  base::c(
    base::paste0(path, ".json"),
    fs::path_ext_set(path, "json"),
    base::paste0(path, ".provenance.json"),
    base::paste0(path, ".metadata.json")
  ) |>
    base::unique()
}


repo_gate_read_accessed_utc <- function(path) {
  candidates <- repo_gate_sidecar_candidates(
    path
  )

  candidates <- candidates[
    fs::file_exists(candidates)
  ]

  if (base::length(candidates) == 0L) {
    return(
      tibble::tibble(
        sidecar = NA_character_,
        accessed_utc = NA_character_
      )
    )
  }

  for (candidate in candidates) {
    metadata <- tryCatch(
      jsonlite::fromJSON(
        candidate,
        simplifyVector = TRUE
      ),
      error = function(err) NULL
    )

    if (base::is.null(metadata)) {
      next
    }

    accessed <- metadata[["accessed_utc"]]

    if (
      !base::is.null(accessed) &&
        base::length(accessed) == 1L &&
        base::nzchar(accessed)
    ) {
      return(
        tibble::tibble(
          sidecar = base::as.character(candidate),
          accessed_utc = base::as.character(accessed)
        )
      )
    }
  }

  tibble::tibble(
    sidecar = base::as.character(candidates[[1L]]),
    accessed_utc = NA_character_
  )
}


repo_gate_valid_utc <- function(value) {
  if (
    base::length(value) != 1L ||
      base::is.na(value) ||
      !base::nzchar(value)
  ) {
    return(FALSE)
  }

  parsed <- base::as.POSIXct(
    value,
    format = "%Y-%m-%dT%H:%M:%OSZ",
    tz = "UTC"
  )

  !base::is.na(parsed)
}


# `since` is a ratchet, not an amnesty. Artifacts already committed without a
# recorded access date cannot have one invented for them -- see the HPSA
# shapefile, whose vintage is gone. New payloads must carry one.
repo_gate_check_access_dates <- function(root, since = NULL) {
  repo_gate_log(
    "Checking artifacts/ for provenance sidecars with accessed_utc"
  )

  paths <- repo_gate_find_artifact_files(root)

  if (base::length(paths) == 0L) {
    repo_gate_log("No artifact payloads found")

    return(tibble::tibble())
  }

  metadata_files <- stringr::str_detect(
    paths,
    "\\.(json|ya?ml|md|txt)$"
  )

  artifact_paths <- paths[!metadata_files]

  if (!base::is.null(since)) {
    artifact_paths <- artifact_paths[
      !base::as.character(fs::path_rel(artifact_paths, root)) %in% since
    ]
  }

  if (base::length(artifact_paths) == 0L) {
    repo_gate_log("No artifact payloads in scope")

    return(tibble::tibble())
  }

  findings <- purrr::map_dfr(
    artifact_paths,
    function(path) {
      provenance <- repo_gate_read_accessed_utc(
        path
      )

      tibble::tibble(
        artifact = base::as.character(fs::path_rel(path, root)),
        sidecar = provenance$sidecar,
        accessed_utc = provenance$accessed_utc,
        valid_accessed_utc = repo_gate_valid_utc(
          provenance$accessed_utc
        )
      )
    }
  ) |>
    dplyr::filter(!.data$valid_accessed_utc)

  repo_gate_log(
    "Artifacts missing valid access dates: ",
    scales::comma(base::nrow(findings))
  )

  findings
}


repo_gate_scan_safe_percent <- function(root, allow = character()) {
  repo_gate_log(
    "Checking analytic code for safe_percent(default = 0)"
  )

  paths <- repo_gate_r_files(root)

  exempt_patterns <- base::c(
    "/tests?/",
    "/testthat/",
    "/fixtures?/",
    allow
  )

  analytic_paths <- paths[
    !purrr::map_lgl(
      paths,
      function(path) {
        base::any(
          stringr::str_detect(
            path,
            exempt_patterns
          )
        )
      }
    )
  ]

  # Matched per line, not across the file. A whole-file [\s\S]*? match reports
  # any file that mentions safe_percent anywhere and default = 0 anywhere,
  # which is most of them, and a gate that cries wolf gets switched off.
  pattern <- "safe_percent\\s*\\([^)]*default\\s*=\\s*0(?:\\.0*)?\\s*[,)]"

  findings <- purrr::map_dfr(
    analytic_paths,
    function(path) {
      lines <- readr::read_lines(path, progress = FALSE)

      matched <- stringr::str_detect(lines, pattern) &
        !stringr::str_detect(lines, "^\\s*#")

      if (!base::any(matched)) {
        return(tibble::tibble())
      }

      tibble::tibble(
        file = base::as.character(path),
        line = base::which(matched),
        text = stringr::str_trim(lines[matched])
      )
    }
  )

  repo_gate_log(
    "Unsafe safe_percent findings: ",
    scales::comma(base::nrow(findings))
  )

  findings
}


repo_gate_format_failure <- function(name, findings) {
  if (base::nrow(findings) == 0L) {
    return("")
  }

  preview <- utils::capture.output(
    base::print(
      utils::head(findings, 20L),
      row.names = FALSE
    )
  )

  base::paste0(
    "\n\n",
    name,
    "\n",
    base::paste(preview, collapse = "\n")
  )
}


run_repo_integrity_gates <- function(
  root = ".",
  ci_entrypoints = base::character(),
  ci_packages = base::character(),
  vendored_pairs = NULL,
  absolute_path_allow = base::character(),
  absolute_path_exclude = base::character(),
  assertion_patterns = base::character(),
  missing_input_ignore = base::character(),
  missing_input_baseline = base::character(),
  access_date_grandfathered = NULL,
  safe_percent_allow = base::character()
) {
  root <- fs::path_abs(root)

  repo_gate_log("Starting repository integrity gates")
  repo_gate_log("Repository root: ", root)

  absolute_paths <- repo_gate_find_absolute_paths(
    root,
    allow = absolute_path_allow,
    exclude = absolute_path_exclude
  )

  missing_packages <- tibble::tibble()

  vacuous_tests <- tibble::tibble()

  if (base::length(ci_entrypoints) > 0L) {
    repo_gate_log(
      "Checking ",
      base::length(ci_entrypoints),
      " CI entrypoints"
    )

    missing_packages <- repo_gate_check_packages(
      entrypoints = ci_entrypoints,
      installed_packages = ci_packages,
      root = root
    )

    vacuous_tests <- repo_gate_check_vacuous_tests(
      entrypoints = ci_entrypoints,
      root = root,
      extra_patterns = assertion_patterns
    )
  }

  vendored_drift <- tibble::tibble()

  if (
    !base::is.null(vendored_pairs) &&
      base::nrow(vendored_pairs) > 0L
  ) {
    vendored_drift <- purrr::map2_dfr(
      vendored_pairs$canonical,
      vendored_pairs$vendored,
      function(canonical_path, vendored_path) {
        repo_gate_compare_vendored_files(
          canonical_path = canonical_path,
          vendored_path = vendored_path,
          root = root
        )
      }
    ) |>
      dplyr::filter(!.data$identical)
  }

  identifiers <- repo_gate_scan_identifiers(
    root
  )

  missing_inputs <- repo_gate_check_missing_inputs(
    root,
    ignored = missing_input_ignore,
    baseline = missing_input_baseline
  )

  access_dates <- repo_gate_check_access_dates(
    root,
    since = access_date_grandfathered
  )

  unsafe_percent <- repo_gate_scan_safe_percent(
    root,
    allow = safe_percent_allow
  )

  failure_count <- base::sum(
    base::nrow(absolute_paths),
    base::nrow(missing_packages),
    base::nrow(vacuous_tests),
    base::nrow(vendored_drift),
    base::nrow(identifiers),
    base::nrow(missing_inputs),
    base::nrow(access_dates),
    base::nrow(unsafe_percent)
  )

  repo_gate_log(
    "Total integrity findings: ",
    scales::comma(failure_count)
  )

  if (failure_count > 0L) {
    message_text <- base::paste0(
      "Repository integrity gates failed.",
      repo_gate_format_failure(
        "Non-hermetic absolute paths:",
        absolute_paths
      ),
      repo_gate_format_failure(
        "Packages missing from CI install set:",
        missing_packages
      ),
      repo_gate_format_failure(
        "Potential vacuous test suites:",
        vacuous_tests
      ),
      repo_gate_format_failure(
        "Vendored-copy drift:",
        vendored_drift
      ),
      repo_gate_format_failure(
        "Identifiers in commit/PR metadata:",
        identifiers
      ),
      repo_gate_format_failure(
        "Missing repository inputs:",
        missing_inputs
      ),
      repo_gate_format_failure(
        "Artifacts without accessed_utc:",
        access_dates
      ),
      repo_gate_format_failure(
        "Unsafe safe_percent(default = 0):",
        unsafe_percent
      )
    )

    base::stop(
      message_text,
      call. = FALSE
    )
  }

  repo_gate_log("All repository integrity gates passed")

  base::invisible(TRUE)
}
