mpralm <- function(object, design,
                   aggregate = c("mean", "sum", "none"),
                   normalize = TRUE,
                   normalizeSize = 10e6,
                   block = NULL,
                   model_type = c("indep_groups", "corr_groups"),
                   plot = TRUE,
                   endomorphic = FALSE,
                   ...) {
    .is_mpra_or_stop(object)
    if (nrow(design) != ncol(object)) {
        stop("Rows of design must correspond to the columns of object")
    }
    
    model_type <- match.arg(model_type)
    aggregate <- match.arg(aggregate)
    
    if (model_type=="indep_groups") {
        fit <- .fit_standard(object = object, design = design,
                             aggregate = aggregate,
                             normalize = normalize,
                             normalizeSize = normalizeSize,
                             plot = plot, ...)
    } else if (model_type=="corr_groups") {
        if (is.null(block)) {
            stop("'block' must be supplied for the corr_groups model type")
        }
        fit <- .fit_corr(object = object, design = design,
                         aggregate = aggregate,
                         normalize = normalize,
                         normalizeSize = normalizeSize,
                         block = block,
                         plot = plot, ...)
    }

    # the default, return the MArrayLM object
    if (!endomorphic) {
        return(fit)
    } else if (endomorphic) {

        # endomorphic means we send back the original object, 'MPRASet'
        # with information attached in relevant slots
        
        if (aggregate == "none" & normalize) {
            # just need to provide the scaled counts
            scaled_object <- normalize_counts(object, normalizeSize = normalizeSize)
            assay(object, "scaledDNA") <- assay(scaled_object, "DNA")
            assay(object, "scaledRNA") <- assay(scaled_object, "RNA")
        }
        if (aggregate != "none") {
            # need to do the aggregation step first
            dna <- getDNA(object, aggregate = TRUE)
            rna <- getRNA(object, aggregate = TRUE)
            if (normalize) {
                # and get the scaled counts
                object <- normalize_counts(object, normalizeSize = normalizeSize)
                scaled_dna <- getDNA(object, aggregate = TRUE)
                scaled_rna <- getRNA(object, aggregate = TRUE)
            }
            object <- object[!duplicated(rowData(object)$eid),]
            rownames(object) <- rowData(object)$eid
            rowData(object)$barcode <- NULL
            assay(object, "DNA") <- dna[rowData(object)$eid,]
            assay(object, "RNA") <- rna[rowData(object)$eid,]
            if (normalize) {
                assay(object, "scaledDNA") <- scaled_dna[rowData(object)$eid,]
                assay(object, "scaledRNA") <- scaled_rna[rowData(object)$eid,]
            }
            if (ncol(rowData(object)) > 1)
                message("rowData columns preserved in aggregation using first occurence of eid")
        }
        attr(object, "MArrayLM") <- fit
        tt <- topTable(fit, ..., number=nrow(fit), sort.by="none")
        stopifnot(all(rownames(tt) %in% rowData(object)$eid))
        tt <- tt[rowData(object)$eid, ]
        rowData(object) <- cbind(rowData(object), tt)
        return(object)
    }
}

get_precision_weights <- function(logr, design, log_dna, span = 0.4,
                                  plot = TRUE, ...) {
    if (nrow(design) != ncol(logr)) {
        stop("Rows of design must correspond to the columns of logr")
    }

    ## Obtain element-specific residual SDs
    fit <- lmFit(logr, design = design, ...)
    s <- fit$sigma
    x <- rowMeans(log_dna, na.rm = TRUE)
    y <- sqrt(s)
    ## Lowess fitting
    lo <- lowess(x, y, f = span)
    if (plot) {
        plot(x, y, pch = 16, col = alpha("black", 0.25),
             xlab = "Mean(log2(dna+1))", ylab = "sqrt(sd(log-ratio))")
        lines(lo, lwd = 3, col = "red")
    }
    loFun <- approxfun(lo, rule = 2)
    ## Use mean log DNA to get estimated sqrt(SD) to
    ## convert to precision weights
    fittedvals <- log_dna
    w <- 1/loFun(fittedvals)^4
    dim(w) <- dim(fittedvals)
    rownames(w) <- rownames(logr)
    colnames(w) <- colnames(logr)

    return(w)
}

compute_logratio <- function(object, aggregate = c("mean", "sum", "none")) {
    .is_mpra_or_stop(object)

    aggregate <- match.arg(aggregate)

    if (aggregate %in% c("sum", "none")) {
        ## Do aggregation even with option "none" to ensure 
        ## matching ordering of eids in logr and log_dna
        dna <- getDNA(object, aggregate = TRUE)
        rna <- getRNA(object, aggregate = TRUE)
        logr <- log2(rna + 1) - log2(dna + 1)
    } else if (aggregate=="mean") {
        dna <- getDNA(object, aggregate = FALSE)
        rna <- getRNA(object, aggregate = FALSE)
        eid <- getEid(object)
        logr <- log2(rna + 1) - log2(dna + 1)
        
        by_out <- by(logr, eid, colMeans, na.rm = TRUE)
        logr <- do.call("rbind", by_out)
        rownames(logr) <- names(by_out)
    }
    return(logr)
}

normalize_counts <- function(object, normalizeSize = 10e6, block = NULL) {
    .is_mpra_or_stop(object)

    ## Perform total count normalization
    dna <- getDNA(object, aggregate = FALSE)
    rna <- getRNA(object, aggregate = FALSE)

    if (is.null(block)) {
        libsizes_dna <- colSums(dna, na.rm = TRUE)
        libsizes_rna <- colSums(rna, na.rm = TRUE)
    } else {
        libsizes_dna <- tapply(colSums(dna, na.rm = TRUE), block,
                               sum, na.rm = TRUE)
        libsizes_dna <- libsizes_dna[block]
        libsizes_rna <- tapply(colSums(rna, na.rm = TRUE), block,
                               sum, na.rm = TRUE)
        libsizes_rna <- libsizes_rna[block]
    }
    dna_norm <- round(sweep(dna, 2, libsizes_dna, FUN = "/") * normalizeSize)
    rna_norm <- round(sweep(rna, 2, libsizes_rna, FUN = "/") * normalizeSize)
    
    assay(object, "DNA") <- dna_norm
    assay(object, "RNA") <- rna_norm

    return(object)
}

.fit_standard <- function(object, design, aggregate = c("mean", "sum", "none"),
                          normalize = TRUE, normalizeSize = normalizeSize,
                          return_elist = FALSE,
                          return_weights = FALSE, plot = TRUE, span = 0.4, ...) {
    .is_mpra_or_stop(object)
    if (nrow(design) != ncol(object)) {
        stop("Rows of design must correspond to the columns of object")
    }

    aggregate <- match.arg(aggregate)

    if (normalize) {
        object <- normalize_counts(object, normalizeSize = normalizeSize)
    }
    logr <- compute_logratio(object, aggregate = aggregate)
    log_dna <- log2(getDNA(object, aggregate = TRUE) + 1)
    
    ## Estimate mean-variance relationship to get precision weights
    w <- get_precision_weights(logr = logr, design = design, log_dna = log_dna,
                               span = span, plot = plot, ...)
    
    elist <- new("EList", list(E = logr, weights = w, design = design))
    
    if (return_weights) {
        return(w)
    }
    if (return_elist) {
        return(elist)
    } 
    fit <- lmFit(elist, design)
    fit <- eBayes(fit)
    fit
}

.fit_corr <- function(object, design, aggregate = c("mean", "sum", "none"),
                      normalize = TRUE, normalizeSize = normalizeSize,
                      block = NULL, return_elist = FALSE,
                      return_weights = FALSE, plot = TRUE, span = 0.4, ...) {
    .is_mpra_or_stop(object)
    if (nrow(design) != ncol(object)) {
        stop("Rows of design must correspond to the columns of object")
    }

    aggregate <- match.arg(aggregate)

    if (normalize) {
        object <- normalize_counts(object, normalizeSize = normalizeSize, block)
    }
    logr <- compute_logratio(object, aggregate = aggregate)
    log_dna <- log2(getDNA(object, aggregate = TRUE) + 1)

    ## Estimate mean-variance relationship to get precision weights
    w <- get_precision_weights(logr = logr, design = design, log_dna = log_dna,
                               span = span, plot = plot, ...)

    ## Estimate correlation between element versions that are paired
    corfit <- duplicateCorrelation(logr, design = design,
                                   ndups = 1, block = block)

    elist <- new("EList", list(E = logr, weights = w, design = design))

    if (return_weights) {
        return(w)
    }
    if (return_elist) {
        return(elist)
    } 

    fit <- lmFit(elist, design, block = block, correlation = corfit$consensus)
    fit <- eBayes(fit)
    fit
}
