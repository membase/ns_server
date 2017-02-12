(function () {
  "use strict";

  angular
    .module("mnUserRoles", [
      "mnUserRolesService",
      "mnHelper",
      "mnPromiseHelper",
      "mnPoll",
      "mnSortableTable",
      "mnSpinner",
      "ui.select",
      "mnLdapService",
      "mnEqual",
      "mnBucketsService",
      "mnFilters"
    ])
    .controller("mnUserRolesController", mnUserRolesController);

  function mnUserRolesController($scope, $uibModal, mnLdapService, mnPromiseHelper, mnUserRolesService, mnPoller, mnHelper, $state, poolDefault, mnBucketsService) {
    var vm = this;
    vm.addUser = addUser;
    vm.deleteUser = deleteUser;
    vm.editUser = editUser;
    vm.resetUserPassword = resetUserPassword;

    vm.toggleSaslauthdAuth = toggleSaslauthdAuth;
    vm.rolesFilter = rolesFilter;

    vm.isLdapEnabled = poolDefault.ldapEnabled;

    vm.pageLimit = $state.params.pageLimit;
    vm.pageNumber = $state.params.pageNumber;
    vm.nextPage = nextPage;
    vm.prevPage = prevPage;
    vm.getPageCountArray = getPageCountArray;
    vm.pageLimitChanged = pageLimitChanged;
    vm.goToPage = goToPage;
    vm.getVisiblePages = getVisiblePages;
    vm.getTotalPageCount = getTotalPageCount;


    activate();

    function getVisiblePages() {
      var totalPageCount = getTotalPageCount();
      var i;
      var array = [];
      for (i = 0; i < totalPageCount; i++){
        array.push(i+1);
      }
      var start = vm.pageNumber - 3;
      var end = vm.pageNumber + 2;
      if (start < 0) {
        start = 0;
      }
      return array.slice(start, end);
    }

    function goToPage(number) {
      vm.pageNumber = number;
      $state.go('.', {
        pageNumber: number
      });
    }

    function nextPage() {
      goToPage(vm.pageNumber + 1);
    }

    function prevPage() {
      goToPage(vm.pageNumber - 1);
    }

    function pageLimitChanged() {
      $state.go('.', {
        pageLimit: vm.pageLimit
      });
    }

    function getTotalPageCount() {
      var num;
      if (!vm.state) {
        num = 1;
      } else {
        num = Math.ceil((vm.state.users.length || 1) / vm.pageLimit);
      }
      return num;
    }

    function getPageCountArray() {
      return new Array(getTotalPageCount());
    }

    function rolesFilter(value) {
      return !value.bucket_name || value.bucket_name === "*";
    }

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedUsers', 'app.admin.security.userRoles');

      if (poolDefault.ldapEnabled) {
        mnPromiseHelper(vm, mnLdapService.getSaslauthdAuth())
          .applyToScope("saslauthdAuth")
          .showSpinner("saslauthdAuthLoading");
      }

      mnPromiseHelper(vm, mnUserRolesService.getRoles())
        .applyToScope(function (roles) {
          vm.roles = roles;
          mnPromiseHelper(vm, mnUserRolesService.getRolesByRole(roles))
            .applyToScope("rolesByRole");
        });

      //redirect to last page if current page became empty
      $scope.$watch(function () {
        if (vm.state) {
          return vm.pageLimit * vm.pageNumber > vm.state.users.length &&
            getTotalPageCount() !== vm.pageNumber;
        }
      }, function (overlimit) {
        if (overlimit) {
          goToPage(getTotalPageCount());
        }
      });

      var poller = new mnPoller($scope, mnUserRolesService.getState)
          .subscribe("state", vm)
          .setInterval(10000)
          .reloadOnScopeEvent("reloadRolesPoller")
          .cycle();

    }

    function toggleSaslauthdAuth() {
      var config = {
        enabled: !vm.saslauthdAuth.enabled
      };
      mnPromiseHelper(vm, mnLdapService.postSaslauthdAuth(config))
        .applyToScope("saslauthdAuth")
        .showSpinner("saslauthdAuthLoading");
    }

    function editUser(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/add_dialog/mn_user_roles_add_dialog.html',
        controller: 'mnUserRolesAddDialogController as userRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user),
          isLdapEnabled: mnHelper.wrapInFunction(poolDefault.ldapEnabled),
          buckets: function () {
            return mnBucketsService.getBucketsByType();
          }
        }
      });
    }
    function addUser() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/add_dialog/mn_user_roles_add_dialog.html',
        controller: 'mnUserRolesAddDialogController as userRolesAddDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(undefined),
          isLdapEnabled: mnHelper.wrapInFunction(poolDefault.ldapEnabled),
          buckets: function () {
            return mnBucketsService.getBucketsByType();
          }
        }
      });
    }
    function resetUserPassword(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/reset_password_dialog/mn_user_roles_reset_password_dialog.html',
        controller: 'mnUserRolesResetPasswordDialogController as userRolesResetPasswordDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user)
        }
      });
    }
    function deleteUser(user) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_security/mn_user_roles/delete_dialog/mn_user_roles_delete_dialog.html',
        controller: 'mnUserRolesDeleteDialogController as userRolesDeleteDialogCtl',
        resolve: {
          user: mnHelper.wrapInFunction(user)
        }
      });
    }
  }
})();
