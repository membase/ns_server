Bugsnag.beforeNotify = (function () {
  var sentReports = 0;
  var ErrorReportsLimit = 8;

  return function logClientError(details, metaData) {
    var report = [];

    if (++sentReports < ErrorReportsLimit) {
      report.push(
        "Got unhandled error:\n",
        details.message,
        "\nAt:\n",
        details.file, ":",
        details.lineNumber, ":",
        details.columnNumber, "\n"
      );

      if (details.stacktrace) {
        report.push("Backtrace:\n", details.stacktrace);
      }
      if (sentReports == ErrorReportsLimit - 1) {
        report.push("Further reports will be suppressed\n");
      }
    }

    // mozilla can report errors in some cases when user leaves current page
    // so delay report sending
    _.delay(function () {
      $.ajax({type: 'POST', url: "/logClientError", data: report.join('')});
    }, 500);

    return false; //this is important for bugsnag.js
  }
})();