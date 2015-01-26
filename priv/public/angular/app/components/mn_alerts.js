angular.module('mnAlertsService').service('mnAlertsService',
  function () {
    var mnAlertsService = {};

    var alerts = [];

    mnAlertsService.setAlert = function (type, message) {
      alerts.push({type: type, msg: message});
    };
    mnAlertsService.setAlerts = function (incomingAlerts) {
      Array.prototype.push.apply(alerts, incomingAlerts);
    };
    mnAlertsService.formatAndSetAlerts = function (incomingAlerts, type) {
      (angular.isArray(incomingAlerts) && angular.isString(incomingAlerts[0])) ||
      (angular.isObject(incomingAlerts) && angular.isString(Object.keys(incomingAlerts)[0])) &&
      angular.forEach(incomingAlerts, function (msg) {
        this.push({type: type, msg: msg});
      }, alerts);
    };

    mnAlertsService.closeAlert = function(index) {
      alerts.splice(index, 1);
    };

    mnAlertsService.alerts = alerts;

    return mnAlertsService;
  });