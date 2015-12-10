(function () {
  "use strict";

  angular
    .module("mnPoorMansAlerts", [
      'ui.router'
    ])
    .factory("mnPoorMansAlerts", mnPoorMansAlertsFactory);

  function mnPoorMansAlertsFactory($http, $state, $uibModal, $rootScope, mnHelper) {
    var alerts = [];
    var modal;
    var mnPoorMansAlerts = {
      maybeShowAlerts: maybeShowAlerts
    };

    return mnPoorMansAlerts;

    function maybeShowAlerts(poolDefault) {
      if ($state.params.disablePoorMansAlerts) {
        return;
      }
      var alerts = getStampedAlerts(poolDefault.alerts);
      if (!alerts.length) {
        return;
      }

      if (modal) {
        modal.dismiss();
      }

      var scope = $rootScope.$new();
      scope.alerts = alerts;
      modal = $uibModal.open({
        scope: scope,
        templateUrl: "app/components/mn_poor_mans_alerts.html"
      });

      modal.result.then(function () {
        $http({
          method: "POST",
          url: poolDefault.alertsSilenceURL,
          timeout: 5000,
          data: ''
        }).then(function () {
          mnHelper.reloadState();
          modal = null;
        });
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
