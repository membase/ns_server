(function () {
  "use strict";

  angular
    .module('mnAlertsService', ['ui.bootstrap'])
    .service('mnAlertsService', mnAlertsServiceFactory);

  function mnAlertsServiceFactory($uibModal, $rootScope) {
    var alerts = [];
    var mnAlertsService = {
      setAlert: setAlert,
      setAlerts: setAlerts,
      formatAndSetAlerts: formatAndSetAlerts,
      showAlertInPopup: showAlertInPopup,
      closeAlert: closeAlert,
      alerts: alerts
    };

    return mnAlertsService;

    function showAlertInPopup(message, title) {
      var scope = $rootScope.$new();
      scope.message = message;
      scope.title = title;
      return $uibModal.open({
        scope: scope,
        templateUrl: "app/components/mn_alerts_popup_message.html"
      }).result;
    }
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
