# Shim: enhanced_name_parsing.R (and friends) call
# here::here("R", "string_normalization.R"), which resolves inside THIS repo.
# Forward to the canonical implementation in the isochrones project.
local({
  iso <- Sys.getenv("ISOCHRONES_R", path.expand("~/isochrones/R"))
  source(file.path(iso, "string_normalization.R"))
})
