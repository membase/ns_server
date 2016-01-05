(function () {
  "use strict";

  angular.module('mnAudit', [
    'mnAuditService',
    'mnHelper',
    'mnPromiseHelper',
    'mnPoolDefault'
  ]).controller('mnAuditController', mnAuditController);

  function mnAuditController($scope, mnAuditService, mnPromiseHelper, mnHelper, mnPoolDefault) {
    var vm = this;

    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.submit = submit;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnAuditService.getAuditSettings())
        .applyToScope("state");

      if (!vm.mnPoolDefault.value.isROAdminCreds) {
        $scope.$watch('auditCtl.state', watchOnState, true);
      }
    }
    function watchOnState(state) {
      if (!state) {
        return;
      }
      mnPromiseHelper(vm, mnAuditService.saveAuditSettings(state, true))
        .catchErrorsFromSuccess();
    }
    function submit() {
      if ($scope.viewLoading) {
        return;
      }
      mnPromiseHelper(vm, mnAuditService.saveAuditSettings(vm.state))
        .catchErrorsFromSuccess()
        .showSpinner()
        .reloadState();
    };
  }
})();
