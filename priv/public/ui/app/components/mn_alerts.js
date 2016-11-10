(function () {
  "use strict";

  angular
    .module('mnAlertsService', ['ui.bootstrap', 'mnFilters'])
    .service('mnAlertsService', mnAlertsServiceFactory);

  function mnAlertsServiceFactory($uibModal, $rootScope) {
    var alerts = [];
    var mnAlertsService = {
      setAlert: setAlert,
      formatAndSetAlerts: formatAndSetAlerts,
      showAlertInPopup: showAlertInPopup,
      closeAlert: closeAlert,
      alerts: alerts
    };

    return mnAlertsService;

    function showAlertInPopup(message, title) {
      var scope = $rootScope.$new();
      scope.alertsCtl = {
        message: message
      };
      scope.title = title;
      return $uibModal.open({
        scope: scope,
        templateUrl: "app/components/mn_alerts_popup_message.html"
      }).result;
    }
    function setAlert(type, message, id) {
      alerts.push({type: type, msg: message, id: id, dismissed: false});
    }
    function formatAndSetAlerts(incomingAlerts, type, timeout) {
      timeout = timeout || 60000;
      if ((angular.isArray(incomingAlerts) && angular.isString(incomingAlerts[0])) || angular.isObject(incomingAlerts)) {
        angular.forEach(incomingAlerts, function (msg) {
          incomingAlerts.push({type: type, msg: msg, timeout: timeout});
        }, alerts);
      }

      angular.isString(incomingAlerts) && alerts.push({type: type, msg: incomingAlerts, timeout: timeout, dismissed: false});
    }
    function closeAlert(alert) {
      alert.dismissed = true;
    }
  }
})();
