#!/usr/bin/env Rscript

if (!requireNamespace("dplyr", quietly = TRUE)) {
  install.packages("dplyr", repos = "https://cloud.r-project.org")
}

library(dplyr)

args <- commandArgs(trailingOnly = TRUE)

if (length(args) != 3) {
  cat("Usage: Rscript merge_hisplex.R <HISplex41_upload.csv> <Result.csv> <output.csv>\n")
  quit(status = 1)
}

upload <- read.csv(args[1], check.names = FALSE)
result <- read.csv(args[2], check.names = FALSE)

merged <- upload %>%
  left_join(result, by = "sampleid")

write.csv(merged, args[3], row.names = FALSE, quote = FALSE, na = "")

cat(sprintf("* Merged %d samples, %d columns → %s\n", nrow(merged), ncol(merged), args[3]))
