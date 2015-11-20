(function () {
  "use strict";

  angular
    .module('mnAlertsService', [])
    .service('mnAlertsService', mnAlertsServiceFactory);

  function mnAlertsServiceFactory() {
    var alerts = [];
    var mnAlertsService = {
      setAlert: setAlert,
      setAlerts: setAlerts,
      formatAndSetAlerts: formatAndSetAlerts,
      closeAlert: closeAlert,
      alerts: alerts
    };

    return mnAlertsService;

    function setAlert(type, message) {
      alerts.push({type: type, msg: message});
    }
    function setAlerts(incomingAlerts) {
      Array.prototype.push.apply(alerts, incomingAlerts);
    }
    function formatAndSetAlerts(incomingAlerts, type, timeout) {
      timeout = timeout || 60000;
      (angular.isArray(incomingAlerts) && angular.isString(incomingAlerts[0])) ||
      (angular.isObject(incomingAlerts) && angular.isString(Object.keys(incomingAlerts)[0])) &&
      angular.forEach(incomingAlerts, function (msg) {
        this.push({type: type, msg: msg, timeout: timeout});
      }, alerts);

      angular.isString(incomingAlerts) && alerts.push({type: type, msg: incomingAlerts, timeout: timeout});
    }
    function closeAlert(index) {
      alerts.splice(index, 1);
    }
  }
})();
