(function () {
  "use strict";

  angular
    .module('mnSettingsNotifications', [
      'mnSettingsNotificationsService',
      'mnPromiseHelper'
    ])
    .controller('mnSettingsNotificationsController', mnSettingsNotificationsController);

  function mnSettingsNotificationsController($scope, mnPromiseHelper, mnSettingsNotificationsService, pools) {
    var vm = this;

    vm.submit = submit;
    vm.implementationVersion = pools.implementationVersion;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.maybeCheckUpdates())
        .applyToScope("updates");
    }

    function submit() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.saveSendStatsFlag(vm.updates.enabled))
        .showGlobalSpinner()
        .catchGlobalErrors('An error occured, update notifications settings were not saved.')
        .showGlobalSuccess("Settings saved successfully!");
    }
  }
})();
