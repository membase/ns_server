(function () {
  "use strict";

  angular
    .module("mnPoorMansAlertsService", [
      'ui.router',
      'ui.bootstrap',
      'mnHelper'
    ])
    .factory("mnPoorMansAlertsService", mnPoorMansAlertsFactory);

  function mnPoorMansAlertsFactory($http, $state, $uibModal, mnHelper, $timeout) {
    var alerts = [];
    var modal;
    var modalDeferId;

    var mnPoorMansAlerts = {
      maybeShowAlerts: maybeShowAlerts,
      postAlertsSilenceURL: postAlertsSilenceURL
    };

    return mnPoorMansAlerts;

    function postAlertsSilenceURL(alertsSilenceURL) {
      return $http({
        method: "POST",
        url: alertsSilenceURL,
        timeout: 5000,
        data: ''
      });
    }

    function maybeShowAlerts(poolDefault) {
      if ($state.params.disablePoorMansAlerts) {
        return;
      }
      alerts = getStampedAlerts(poolDefault.alerts);
      if (!alerts.length) {
        return;
      }
      if (modalDeferId) {
        $timeout.cancel(modalDeferId);
      }
      if (modal) {
        modal.dismiss();
        modal = null;
        modalDeferId = $timeout(function () { //we need this in order to allow uibModal close backdrop
          modal = doShowAlerts(poolDefault.alertsSilenceURL, alerts);
        }, 0);
      } else {
        modal = doShowAlerts(poolDefault.alertsSilenceURL, alerts);
      }
    }

    function doShowAlerts(alertsSilenceURL, alerts) {
      return $uibModal.open({
        templateUrl: "app/mn_admin/mn_poor_mans_alerts/mn_poor_mans_alerts.html",
        controller: "mnPoorMansAlertsController as poorMansCtl",
        resolve: {
          alertsSilenceURL: mnHelper.wrapInFunction(alertsSilenceURL),
          alerts: mnHelper.wrapInFunction(alerts)
        }
      });
    }

    function getStampedAlerts(newRawAlerts) {
      var oldStampedAlerts = alerts;
      if (!newRawAlerts) {
        return oldStampedAlerts;
      }
      var i;
      if (oldStampedAlerts.length > newRawAlerts.length) {
        oldStampedAlerts = [];
      }
      for (i = 0; i < oldStampedAlerts.length; i++) {
        if (oldStampedAlerts[i][1] != newRawAlerts[i]) {
          break;
        }
      }
      var rv = (i == oldStampedAlerts.length) ? _.clone(oldStampedAlerts) : [];
      _.each(newRawAlerts.slice(rv.length), function (msg) {
        rv.push([new Date(), msg]);
      });
      return rv;
    }
  }
})();
