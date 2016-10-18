(function () {
  "use strict";

  angular.module('mnSettingsAutoFailover', [
    'mnSettingsAutoFailoverService',
    'mnHelper',
    'mnPromiseHelper'
  ]).controller('mnSettingsAutoFailoverController', mnSettingsAutoFailoverController);

  function mnSettingsAutoFailoverController($scope, mnHelper, mnPromiseHelper, mnSettingsAutoFailoverService) {
    var vm = this;

    vm.isAutoFailOverDisabled = isAutoFailOverDisabled;
    vm.submit = submit;

    activate();

    function watchOnAutoFailoverSettings() {
      if (!$scope.rbac.cluster.settings.write) {
        return;
      }
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.saveAutoFailoverSettings({
        enabled: vm.state.enabled,
        timeout: vm.state.timeout
      }, {
        just_validate: 1
      })).catchErrorsFromSuccess();
    }

    function activate() {
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.getAutoFailoverSettings())
        .applyToScope(function (autoFailoverSettings) {
          vm.state = autoFailoverSettings.data;
          $scope.$watch('settingsAutoFailoverCtl.state', _.debounce(watchOnAutoFailoverSettings, 500, {leading: true}), true);
        });
    }
    function isAutoFailOverDisabled() {
      return !vm.state || !vm.state.enabled;
    }
    function submit() {
      var data = {
        enabled: vm.state.enabled,
        timeout: vm.state.timeout
      };
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.saveAutoFailoverSettings(data))
        .showGlobalSpinner()
        .catchErrors();
    };
  }
})();
