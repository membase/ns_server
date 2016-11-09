(function () {
  "use strict";

  angular
    .module("mnLostConnectionService", [
      "mnHelper",
      "ui.bootstrap"
    ])
    .factory("mnLostConnectionService", mnLostConnectionFactory);

  function mnLostConnectionFactory($interval, mnHelper, $uibModalStack) {
    var repeatAt = 3.09;
    var state = {
      isActivated: false
    };
    var mnLostConnectionService = {
      activate: activate,
      deactivate: deactivate,
      getState: getState
    };
    return mnLostConnectionService;

    function activate() {
      if (state.isActivated) {
        return;
      }
      repeatAt = Math.round(Math.min(repeatAt * 1.618, 300));
      state.repeatAt = repeatAt;
      state.isActivated = true;
      state.interval = $interval(function () {
        state.repeatAt -= 1;
        if (state.repeatAt === -1) {
          deactivate();
        }
      }, 1000);
    }

    function deactivate() {
      if (state.isActivated) {
        state.isActivated = false;
        $interval.cancel(state.interval);
        state.interval = null;
        $uibModalStack.dismissAll();
        mnHelper.reloadState();
      }
    }

    function getState() {
      return state;
    }
  }
})();
