(function () {
  "use strict";

  angular.module('mnSettingsAutoFailover', [
    'mnSettingsAutoFailoverService',
    'mnHelper',
    'mnPromiseHelper'
  ]).controller('mnSettingsAutoFailoverController', mnSettingsAutoFailoverController);

  function mnSettingsAutoFailoverController($scope, mnHelper, mnPromiseHelper, mnSettingsAutoFailoverService, mnPoolDefault) {
    var vm = this;

    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.isAutoFailOverDisabled = isAutoFailOverDisabled;
    vm.submit = submit;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.getAutoFailoverSettings())
        .applyToScope(function (autoFailoverSettings) {
          vm.state = autoFailoverSettings.data;
        });
    }
    function isAutoFailOverDisabled() {
      return !vm.state || !vm.state.enabled || vm.mnPoolDefault.value.isROAdminCreds;
    }
    function submit() {
      var data = {
        enabled: vm.state.enabled,
        timeout: vm.state.timeout
      };
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.saveAutoFailoverSettings(data))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, auto-failover settings were not saved.')
        .reloadState();
    };
  }
})();
