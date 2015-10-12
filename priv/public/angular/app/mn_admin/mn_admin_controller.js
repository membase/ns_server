(function () {
  angular.module('mnAdmin').controller('mnAdminController', mnAdminController);

  function mnAdminController($scope, $rootScope, $q, mnSettingsNotificationsService, mnPromiseHelper, pools, mnPoll, mnAuthService, mnTasksDetails, mnAlertsService, mnPoolDefault, mnSettingsAutoFailoverService) {
    var vm = this;
    vm.launchpadId = pools.launchID;
    vm.alerts = mnAlertsService.alerts;
    vm.closeAlert = mnAlertsService.closeAlert;
    vm.logout = mnAuthService.logout;
    vm.resetAutoFailOverCount = resetAutoFailOverCount;
    vm.isProgressBarClosed = true;
    vm.areThereMoreThenTwoRunningTasks = areThereMoreThenTwoRunningTasks;
    vm.toggleProgressBar = toggleProgressBar;

    activate();

    function areThereMoreThenTwoRunningTasks() {
      return vm.tasks && vm.tasks.running.length > 1;
    }

    function toggleProgressBar() {
      vm.isProgressBarClosed = !vm.isProgressBarClosed;
    }

    function resetAutoFailOverCount() {
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.resetAutoFailOverCount())
        .showSpinner('resetQuotaLoading')
        .catchGlobalErrors('Unable to reset the auto-failover quota!')
        .reloadState()
        .cancelOnScopeDestroy($scope);
    }

    function activate() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.maybeCheckUpdates())
        .applyToScope("updates")
        .onSuccess(function (updates) {
          if (updates.sendStats) {
            mnPromiseHelper(vm, mnSettingsNotificationsService.buildPhoneHomeThingy())
              .applyToScope("launchpadSource")
              .independentOfScope();
          }
        })
        .independentOfScope();

      mnPoll
        .start($scope, function () {
          return $q.all([
            mnTasksDetails.get(),
            mnPoolDefault.getFresh()
          ]);
        })
        .subscribe(function (resp) {
          vm.tasks = resp[0];
          $rootScope.tabName = resp[1] && resp[1].clusterName;
          vm.mnPoolDefault = resp[1];
        })
        .keepIn("mnAdminState", vm)
        .cancelOnScopeDestroy()
        .run();
    }

  }
})();
