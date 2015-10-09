(function () {
  angular.module('mnSettingsNotifications', [
    'mnSettingsNotificationsService',
    'mnPromiseHelper'
  ]).controller('mnSettingsNotificationsController', mnSettingsNotificationsController);

  function mnSettingsNotificationsController($scope, mnPromiseHelper, mnSettingsNotificationsService) {
    var vm = this;

    vm.submit = submit;

    function submit() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.saveSendStatsFlag($scope.mnAdminController.updates.enabled))
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors('An error occured, update notifications settings were not saved.')
        .reloadState()
        .cancelOnScopeDestroy($scope);
    }
  }
})();
