(function () {
  "use strict";

  angular
    .module("mnAccountManagement", [
      "mnAccountManagementService",
      "mnPromiseHelper",
      "mnHelper",
      "mnSpinner",
      "mnPoolDefault"
    ])
    .controller("mnAccountManagementController", mnAccountManagementController);

  function mnAccountManagementController($scope, $modal, mnAccountManagementService, mnPromiseHelper, mnHelper, mnPoolDefault) {
    var vm = this;

    vm.creds = {};

    vm.createUser = createUser;
    vm.deleteUser = deleteUser;
    vm.resetUserPassword = resetUserPassword;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    if (vm.mnPoolDefault.isROAdminCreds) {
      return;
    }

    activate();

    function deleteUser() {
      return $modal.open({
        templateUrl: 'mn_admin/mn_settings/account_management/delete/mn_account_management_delete.html',
        controller: 'mnAccountManagementDeleteController as mnAccountManagementDeleteController',
        resolve: {
          name: mnHelper.wrapInFunction(vm.roAdminName)
        }
      });
    }
    function resetUserPassword() {
      return $modal.open({
        templateUrl: 'mn_admin/mn_settings/account_management/reset/mn_account_management_reset.html',
        controller: 'mnAccountManagementResetController as mnAccountManagementResetController'
      });
    }
    function createUser() {
      if (vm.viewLoading) {
        return;
      }

      mnPromiseHelper(vm, mnAccountManagementService.postReadOnlyAdminName(vm.creds, true))
        .cancelOnScopeDestroy($scope)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .onSuccess(function () {
          mnPromiseHelper(vm, mnAccountManagementService.postReadOnlyAdminName(vm.creds))
            .cancelOnScopeDestroy($scope)
            .reloadState();
        });
    }
    function activate() {
      mnPromiseHelper(vm, mnAccountManagementService.getAccountManagmentState())
        .cancelOnScopeDestroy($scope)
        .showSpinner()
        .applyToScope("roAdminName");
    }
  }
})();
