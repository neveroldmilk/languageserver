#' diagnostics
#'
#' Diagnose problems in files after linting.
#'
#' @name diagnostics
NULL

DiagnosticSeverity <- list(
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4
)

#' @rdname diagnostics
#' @keywords internal
diagnostic_range <- function(result, content) {
    line <- result$line_number - 1
    column <- result$column_number - 1
    text <- if (line + 1 <= length(content)) content[line + 1] else ""
    if (is.null(result$ranges)) {
        cols <- code_point_to_unit(text, c(column, column + 1))
        range(
            start = position(line = line, character = cols[1]),
            end = position(line = line, character = cols[2])
        )
    } else {
        cols <- code_point_to_unit(text, c(result$ranges[[1]][1] - 1, result$ranges[[1]][2]))
        range(
            start = position(line = line, character = cols[1]),
            end = position(line = line, character = cols[2])
        )
    }
}

#' @rdname diagnostics
#' @keywords internal
diagnostic_severity <- function(result) {
    switch(result$type,
        error = DiagnosticSeverity$Error,
        warning = DiagnosticSeverity$Warning,
        style = DiagnosticSeverity$Information,
        DiagnosticSeverity$Information)
}

#' @rdname diagnostics
#' @keywords internal
diagnostic_from_lint <- function(result, content) {
    list(
        range = diagnostic_range(result, content),
        severity = diagnostic_severity(result),
        source = result$linter,
        message = result$message
    )
}

#' Find the lintr config file
#' @keywords internal
find_config <- function(filename) {
    # instead of calling `lintr:::find_config` directly
    # since CRAN doesn't like :::.
    asNamespace("lintr")$find_config(filename)
}

#' Run diagnostic on a file
#'
#' Lint and diagnose problems in a file.
#' @keywords internal
diagnose_file <- function(uri, content) {
    if (length(content) == 0) {
        return(list())
    }

    if (is_rmarkdown(uri)) {
        # make sure Rmarkdown file has at least one block
        if (!any(stringi::stri_detect_regex(content, "```\\{r[ ,\\}]"))) {
            return(list())
        }
    }

    path <- path_from_uri(uri)
    linter_file <- find_config(path)
    if (is.null(linter_file)) {
        linters <- getOption("languageserver.default_linters", NULL)
    } else {
        linters <- NULL
        op <- options(lintr.linter_file = linter_file)
        on.exit(options(op))
    }

    if (length(content) == 1) {
        content <- c(content, "")
    }

    text <- paste0(content, collapse = "\n")
    diagnostics <- lapply(
        lintr::lint(text, linters = linters), diagnostic_from_lint, content = content)
    names(diagnostics) <- NULL
    diagnostics
}


diagnostics_callback <- function(self, uri, version, diagnostics) {
    if (is.null(diagnostics) || !self$workspace$documents$has(uri)) return(NULL)
    logger$info("diagnostics_callback called:", list(uri = uri, version = version))
    # logger$info("diagnostics:", diagnostics)
    self$deliver(
        Notification$new(
            method = "textDocument/publishDiagnostics",
            params = list(
                uri = uri,
                diagnostics = diagnostics
            )
        )
    )
}


diagnostics_task <- function(self, uri, document, delay = 0) {
    version <- document$version
    content <- document$content
    create_task(
        target = package_call(diagnose_file),
        args = list(uri = uri, content = content),
        callback = function(result) diagnostics_callback(self, uri, version, result),
        error = function(e) {
            logger$info("diagnostics_task:", e)
            diagnostics_callback(self, uri, version, list(list(
                range = range(
                    start = position(0, 0),
                    end = position(0, 0)
                ),
                severity = DiagnosticSeverity$Error,
                source = "lintr",
                message = paste0("Failed to run diagnostics: ", conditionMessage(e))
            )))
        },
        delay = delay
    )
}
