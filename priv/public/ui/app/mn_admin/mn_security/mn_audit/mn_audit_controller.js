(function () {
  "use strict";

  angular.module('mnAudit', [
    'mnAuditService',
    'mnHelper',
    'mnPromiseHelper'
  ]).controller('mnAuditController', mnAuditController);

  function mnAuditController($scope, mnAuditService, mnPromiseHelper, mnHelper) {
    var vm = this;

    vm.submit = submit;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnAuditService.getAuditSettings())
        .applyToScope("state");

      $scope.$watch('auditCtl.state', watchOnState, true);
    }
    function watchOnState(state) {
      if (!state || !$scope.rbac.cluster.admin.security.write) {
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
        .reloadState()
        .showGlobalSuccess("Audit settings changed successfully!", 4000);
    };
  }
})();
