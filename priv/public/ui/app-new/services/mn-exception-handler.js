var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnExceptionHandler = (function () {
  "use strict";
  var errorReportsLimit = 8;
  var sentReports = 0;

  var MnExceptionHandler =
      ng.core.Injectable()
      .Class({
        constructor: [
          ng.common.http.HttpClient,
          function MnExceptionHandlerService(http) {
            this.http = http;
          }],
        // TransitionRejection types
        // 2 "SUPERSEDED";
        // 3 "ABORTED";
        // 4 "INVALID";
        // 5 "IGNORED";
        // 6 "ERROR";
        handleError: function (exception, cause) {
          var unwantedTransitionError = //we are not interested in these Rejection exceptions;
              exception.constructor.name === "Rejection" &&
              (exception.type === 2 || exception.type === 3 || exception.type === 5);
          var unwantedHttpError =
              exception instanceof ng.common.http.HttpErrorResponse;
          var overlimit =
              sentReports >= errorReportsLimit;
          var doSend;

          if (!unwantedTransitionError && !unwantedHttpError) {
            if (!overlimit) {
              doSend = this.send(exception);

              if (doSend) {
                doSend.then(function (resp) {
                  sentReports++;
                  return resp;
                }, function () {
                  //ignore 401
                });
              }
            }

            console.log(exception);
          }
        },
        formatErrorMessage: function (exception) {
          var error = ["Got unhandled javascript error:\n"];
          var props = ["name", "message", "fileName", "lineNumber", "columnNumber", "stack", "detail"];
          props.forEach(function (property) {
            if (exception[property]) {
              error.push(property + ": " + exception[property] + ";\n");
            }
          });
          if (sentReports >= (errorReportsLimit - 1)) {
            error.push("Further reports will be suppressed\n");
          }
          return error.join("");
        },
        send: function (exception) {
          var error = this.formatErrorMessage(exception);
          if (error) {
            return this.http.post("/logClientError", error).toPromise();
          }
        }
      });

  return MnExceptionHandler;
})();
