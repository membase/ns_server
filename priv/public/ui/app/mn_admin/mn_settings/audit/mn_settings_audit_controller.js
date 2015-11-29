(function () {
  "use strict";

  angular.module('mnSettingsAudit', [
    'mnSettingsAuditService',
    'mnHelper',
    'mnPromiseHelper',
    'mnPoolDefault'
  ]).controller('mnSettingsAuditController', mnSettingsAuditController);

  function mnSettingsAuditController($scope, mnSettingsAuditService, mnPromiseHelper, mnHelper, mnPoolDefault) {
    var vm = this;

    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.submit = submit;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnSettingsAuditService.getAuditSettings())
        .applyToScope("state");

      if (!vm.mnPoolDefault.value.isROAdminCreds) {
        $scope.$watch('settingsAuditCtl.state', watchOnState, true);
      }
    }
    function watchOnState(state) {
      if (!state) {
        return;
      }
      mnPromiseHelper(vm, mnSettingsAuditService.saveAuditSettings(state, true))
        .catchErrorsFromSuccess()
        .cancelOnScopeDestroy($scope);
    }
    function submit() {
      if ($scope.viewLoading) {
        return;
      }
      mnPromiseHelper(vm, mnSettingsAuditService.saveAuditSettings(vm.state))
        .catchErrorsFromSuccess()
        .showSpinner()
        .reloadState()
        .cancelOnScopeDestroy($scope);
    };
  }
})();
