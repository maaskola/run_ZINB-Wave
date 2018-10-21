#!/usr/bin/env Rscript

install_package <- FALSE

if (install_package) {
  source("https://bioconductor.org/biocLite.R")
  biocLite("zinbwave")
}

library(optparse, quietly=TRUE)

# Register BiocParallel Serial Execution
BiocParallel::register(BiocParallel::SerialParam())

mob_paths <- list.files("~/expression/mob16", "mob_.*.tsv.gz", full.names=TRUE)
brain_paths <- list.files("~/expression/mob-hippocampus/transposed/hippocampus/", "wt_rep.*.tsv.gz", full.names=TRUE)

verbose = TRUE

parse_cli_args <- function() {
  proposed_out_prefix <- gsub(" ", "_", paste("zinbwave", Sys.time()))
  option_list = list(
                     make_option(c("-k", "--types"), type="numeric", default=10,
                                 help="number of types to use [default = 10]",
                                 metavar="N"),
                     make_option(c("", "--top"), type="numeric", default=100,
                                 help="number of most variable genes to use [default = 100]",
                                 metavar="N"),
                     make_option(c("-t", "--transpose"), type="logical", default=FALSE,
                                 help="ensure that genes are rows and columns are spots; use this option if spots are rows and genes are columns",
                                 action="store_true"),
                     make_option(c("-v", "--verbose"), type="logical", default=FALSE,
                                 help="be verbose",
                                 action="store_true"),
                     make_option(c("-d", "--design"), type="character", default=NULL,
                                 help="specify the path to a design specification file",
                                 action="store"),
                     make_option(c("-o", "--out"), type="character", default="./",
                                 help=paste0("specify output path prefix [autogenerated = ", proposed_out_prefix, "]"),
                                 action="store")
                     );

  opt_parser = OptionParser(option_list = option_list);
  parse_args(opt_parser, positional_arguments = c(0, Inf));
}

if (!interactive()) {
  opt <- parse_cli_args()
  verbose <- opt$option$verbose
  if (verbose)
    print(opt)
}

suppressPackageStartupMessages({
  library(zinbwave)
  library(scRNAseq)
  library(matrixStats)
  library(magrittr)
  library(ggplot2)
  library(biomaRt)
})

st.load.matrix = function(path, suffix="", row.names=1, ...) {
  x = c()
  tmp = try({ x = read.delim(paste(path, suffix, sep=""),
                                    header=T,
                                    row.names=row.names,
                                    sep="\t",
                                    check.names=F,
                                    ...)})

  if(inherits(tmp, 'try-error')) {
    return(as.matrix(c()))
  } else {
    return(as.matrix(x))
  }
}

load_design <- function(path, use.names=FALSE) {
  design = as.data.frame(st.load.matrix(path))
  for (i in 1:ncol(design))
    design[,i] <- as.factor(design[,i])
  if (use.names & "name" %in% colnames(design))
    rownames(design) <- design$name
  drop_covars <- c("name", "coord", "1", "path")
  print(design)
  design <- design[, !colnames(design) %in% drop_covars, drop=FALSE]
  if (!"section" %in% colnames(design))
    design = cbind(design, section=1:nrow(design))
  if(length(unique(sort(design[,"section"]))) < 2)
    design <- design[,colnames(design) != "section", drop=FALSE]
  print("Design:")
  print(design)
  design
}

make_beta_sample_feature <- function(design) {
  nr <- dim(design)[1]
  m <- matrix(0, nrow=nr, ncol=0)
  # rownames(m) <- rownames(design)

  for (col_idx in 1:ncol(design)) {
    feature = colnames(design)[col_idx]
    # print(paste("processing column", col_idx, feature))

    fact <- as.factor(design[, col_idx])
    nc <- length(levels(fact))
    n <- matrix(0, nrow=nr, ncol=nc)
    colnames(n) <- paste(feature, levels(fact), sep="_")
    for(i in 1:nr)
      n[i, fact[i]] <- 1
    m <- cbind(m, n)

  }
  print("beta sample feature:")
  print(m)
  m
}

make_beta_spot_sample <- function(section) {
  nr <- length(section)
  nc <- max(section)
  m <- matrix(0, nrow=nr, ncol=nc)
  for(i in 1:nr)
    m[i, section[i]] = 1
  m
}

load_design_or_paths <- function(paths, design_path) {
  if (is.null(design_path)) {
    if (length(paths) == 0)
      rlang::abort("Need to specify either a design matrix path or a set of paths for count matrices. You specified neither.")
    design <- data.frame(section=1:length(paths))
    rownames(design) = paths
    if (length(paths) == 1)
      design <- design[,-1]
  } else {
    if (length(paths) > 0) {
      rlang::abort("Need to specify either a design matrix path or a set of paths for count matrices. You specified both.")
    }
    design <- load_design(design_path)
    paths <- rownames(design)
  }
  design
}

# assume paths are for count matrices with spots in rows and genes in columns
load_data <- function(paths=c(), design_path=NULL, transpose=FALSE) {
  design <- load_design_or_paths(paths, design_path)
  counts <- list()
  colData <- c()
  for (path in rownames(design)) {
    print(path)
    count <- st.load.matrix(path)
    if (transpose)
      count = t(count)
    # print(count[1:10,1:10])
    counts[[path]] = count
  }

  genes <- c()
  for (count in counts)
    genes <- union(genes, rownames(count))

  section <- c()
  coord <- c()
  m <- matrix(0, nrow=length(genes), ncol=0)
  rownames(m) <- genes
  idx <- 1
  for (count in counts) {
    n <- matrix(0, nrow=length(genes), ncol=ncol(count))
    rownames(n) <- genes
    colnames(n) <- paste(idx, colnames(count))
    n[rownames(count),] = count
    m <- cbind(m, n)
    section <- c(section, rep(idx, ncol(count)))
    coord <- c(coord, colnames(count))
    idx <- idx + 1
  }

  coord <- matrix(unlist(lapply(strsplit(coord, "x"), as.numeric)), ncol=2, byrow=TRUE)

  if (!is.null(design)) {
    beta_sample_feature <- make_beta_sample_feature(design)
    beta_spot_sample <- make_beta_spot_sample(section)
    beta = beta_spot_sample %*% beta_sample_feature
    if (FALSE) {
      print("beta_sample_feature")
      print(beta_sample_feature)
      print("beta_spot_sample")
      print(beta_spot_sample)
      print("beta")
      print(beta)
    }
  } else {
    print("error: foo has been barred")
    exit(-1)
  }

  beta = cbind(baseline=1, beta)
  colData <- cbind(beta, section, x=coord[,1], y=coord[,2])
  print(head(colData))


  SummarizedExperiment(assays=list(counts=m), colData=colData)
}

analyze <- function(expr, K=2, num_genes=100) {
  print("Before filtering")
  print(dim(expr))
  filter <- rowSums(assay(expr)>5)>5
  print("Gene filter statistics")
  print(table(filter))

  expr <- expr[filter,]
  print("After gene filtering")
  print(dim(expr))

  filter <- colSums(assay(expr)>5)>5
  print("Spot filter statistics")
  print(table(filter))

  expr <- expr[,filter]
  print("After spot filtering")
  print(dim(expr))

  assay(expr) %>% log1p %>% rowVars -> vars
  names(vars) <- rownames(expr)
  vars <- sort(vars, decreasing = TRUE)
  # print(head(vars))

  if (num_genes > 0)
    expr <- expr[names(vars)[1:num_genes],]

  assayNames(expr)[1] <- "counts"

  cols <- colnames(colData(expr))
  cols <- cols[!cols %in% c("path", "coord", "x", "y", "name", "section")]
  my_formula = paste0("~", paste(cols, collapse="+"))
  print("using formula:")
  print(my_formula)
  zinb <- zinbwave(expr, K=K, epsilon=1000, X=my_formula, verbose=verbose) #, BPPARAM=MulticoreParam(4))

  zinb
}

visualize_it <- function(zinb, output_prefix=NULL) {
  coords <- cbind(x=zinb$x, y=zinb$y)
  sections <- unique(sort(zinb$section))

  W <- reducedDim(zinb)
  if (!is.null(output_prefix)) {
    write.table(W, file=paste0(output_prefix, "ZINB-WaVE-output.tsv"), sep="\t", quote=FALSE)
    write.table(colData(zinb), file=paste0(output_prefix, "ZINB-WaVE-colData.tsv"), sep="\t", quote=FALSE)
    for (section_idx in sections) {
      these <- zinb$section==section_idx
      w <- W[these,]
      rownames(w) <- gsub(".* ", "", rownames(w))
      write.table(w, file=paste0(output_prefix, "ZINB-WaVE-output-section", section_idx, ".tsv"), sep="\t", quote=FALSE)
    }
  }

  data.frame(W, section=as.character(zinb$section)) %>%
    ggplot(aes(W1, W2, colour=section)) + geom_point() +
    scale_color_brewer(type = "qual", palette = "Set1") +
    coord_equal() + theme_classic()
  ggsave(paste0(output_prefix, "ZINB-WaVE-ggplot-scatter-W1-W2.pdf"))

  uniformize <- function(x) {
    apply(x, 2, function(y) { z <- y - min(y); z / max(z) })
  }

  num_plot_rows <- ceiling(sqrt(length(unique(sort(zinb$section)))))
  pdf(paste0(output_prefix, "ZINB-WaVE-ggplot-spatial.pdf"), width=6*num_plot_rows, height=6*num_plot_rows)
  for(n in 1:ncol(W)) {
    p <- data.frame(z=W[,n], x=zinb$x, y=zinb$y, section=as.character(zinb$section)) %>%
      # ggplot(aes(x, y)) + geom_point() +
      ggplot(aes(x, y, color=z)) + geom_point(size=8) +
      # scale_color_gradient(aes(color=W1)) +
      facet_wrap(~section, nrow=num_plot_rows) +
      coord_equal() + theme_classic()
    print(p)
  }
  dev.off()



  n <- ceiling(sqrt(length(sections)))
  pdf(paste0(output_prefix, "ZINB-WaVE-visual.pdf"), width=n*6, height=n*6)
  for (col_idx in 1:ncol(W)) {
    par(mfrow=c(n, n))
    for (section_idx in sections) {
      these <- zinb$section==section_idx
      w <- W[these, col_idx]
      visualize(w, coords=coords[these,])
    }
  }
  dev.off()
}

doit <- function(expr, types=2, output_prefix="./", num_genes=100) {
  zinb <- analyze(expr, K=types, num_genes=num_genes)
  visualize_it(zinb, output_prefix=output_prefix)
  zinb
}

main_fluidigm <- function(...) {
  data("fluidigm")
  doit(fluidigm, ...)
}

main <- function(paths, opt) {
  expr <- load_data(paths=paths, design_path=opt$options$design, transpose=opt$options$transpose)
  doit(expr, types=opt$options$types, output_prefix=opt$options$out, num_genes=opt$options$top)
}

if(!interactive()) {

  # paths <- commandArgs(trailingOnly=TRUE)
  paths <- opt$args
  main(paths, opt)
}