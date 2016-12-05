(function () {
  "use strict";

  angular
    .module("mnLostConnectionService", [
      "mnHelper",
      "ui.bootstrap"
    ])
    .factory("mnLostConnectionService", mnLostConnectionFactory);

  function mnLostConnectionFactory($interval, mnHelper, $uibModalStack, $window) {
    var repeatAt = 3.09;
    var state = {
      isActivated: false,
      isReloading: false
    };
    var mnLostConnectionService = {
      activate: activate,
      deactivate: deactivate,
      getState: getState,
      resendQueries: resendQueries
    };
    return mnLostConnectionService;

    function activate() {
      if (state.isActivated && !state.isReseted) {
        return;
      }
      state.isActivated = true;
      state.isReseted = false;
      resetTimer();
      runTimer();
    }

    function runTimer() {
      state.interval = $interval(function () {
        state.repeatAt -= 1;
        if (state.repeatAt === 0) {
          $uibModalStack.dismissAll();
          resendQueries();
        }
      }, 1000);
    }

    function resetTimer() {
      $interval.cancel(state.interval);
      state.interval = null;
      repeatAt = Math.round(Math.min(repeatAt * 1.6, 300));
      state.repeatAt = repeatAt;
    }

    function resendQueries() {
      state.isReloading = true;
      state.isReseted = true;
      mnHelper.reloadState().then(null, function () {
        state.isReloading = false;
      });
    }

    function deactivate() {
      if (state.isActivated) {
        state.isReloading = true;
        $interval.cancel(state.interval);
        $window.location.reload(true);// completely reinitialize application after lost of connection

      }
    }

    function getState() {
      return state;
    }
  }
})();
