(function () {
  "use strict";

  angular
    .module('mnSettingsNotifications', [
      'mnSettingsNotificationsService',
      'mnPromiseHelper',
      'mnPoolDefault'
    ])
    .controller('mnSettingsNotificationsController', mnSettingsNotificationsController);

  function mnSettingsNotificationsController($scope, mnPromiseHelper, mnSettingsNotificationsService, mnPoolDefault, pools) {
    var vm = this;

    vm.submit = submit;
    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.implementationVersion = pools.implementationVersion;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.maybeCheckUpdates())
        .applyToScope("updates");
    }

    function submit() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.saveSendStatsFlag(vm.updates.enabled))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, update notifications settings were not saved.')
        .reloadState()
        .cancelOnScopeDestroy($scope);
    }
  }
})();
