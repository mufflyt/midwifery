# Shim: enhanced_name_parsing.R (and friends) call
# here::here("R", "string_normalization.R"), which resolves inside THIS repo.
# Forward to the canonical implementation in the isochrones project.
#
# CYCLE 4. This used to source() the target unconditionally. When ~/isochrones
# was absent or moved, R reported only "cannot open the connection" -- naming
# neither the file it wanted nor the variable that would fix it. The standing
# rule for this project is that a missing authoritative engine fails LOUDLY
# with instructions, and never falls back to a local reimplementation, because
# a second copy of a name-normalisation rule is how two pipelines quietly
# disagree about who matched whom.
local({
  iso <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
  target <- file.path(iso, "string_normalization.R")
  if (!file.exists(target)) {
    stop(sprintf(paste0(
      "Canonical string_normalization.R not found.\n",
      "  Looked in : %s\n",
      "  Resolved from: %s\n",
      "  Fix: point ISOCHRONES_R at the isochrones R/ directory, e.g.\n",
      "         Sys.setenv(ISOCHRONES_R = \"~/isochrones/R\")\n",
      "       or add it to ~/.Renviron (NOT a project-level .Renviron, which\n",
      "       shadows the home one).\n",
      "  Do NOT vendor a local copy -- name normalisation must have exactly\n",
      "  one definition across the pipelines that compare names."),
      target,
      if (nzchar(Sys.getenv("ISOCHRONES_R"))) "$ISOCHRONES_R" else "the ~/isochrones default"),
      call. = FALSE)
  }
  source(target)
})
