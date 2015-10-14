(function () {
  angular.module('mnSettingsNotifications', [
    'mnSettingsNotificationsService',
    'mnPromiseHelper',
    'mnPoolDefault'
  ]).controller('mnSettingsNotificationsController', mnSettingsNotificationsController);

  function mnSettingsNotificationsController($scope, mnPromiseHelper, mnSettingsNotificationsService, mnPoolDefault) {
    var vm = this;

    vm.submit = submit;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    function submit() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.saveSendStatsFlag($scope.mnAdminController.updates.enabled))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, update notifications settings were not saved.')
        .reloadState()
        .cancelOnScopeDestroy($scope);
    }
  }
})();
