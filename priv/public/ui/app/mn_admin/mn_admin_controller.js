(function () {
  "use strict";

  angular
    .module('mnAdmin')
    .controller('mnAdminController', mnAdminController);

  function mnAdminController($scope, $rootScope, poolDefault, mnAboutDialogService, mnSettingsNotificationsService, mnPromiseHelper, pools, mnPoller, mnEtagPoller, mnAuthService, mnTasksDetails, mnAlertsService, mnPoolDefault, mnSettingsAutoFailoverService, formatProgressMessageFilter, parseVersionFilter, mnPluggableUiRegistry) {
    var vm = this;
    vm.poolDefault = poolDefault;
    vm.launchpadId = pools.launchID;
    vm.alerts = mnAlertsService.alerts;
    vm.closeAlert = mnAlertsService.closeAlert;
    vm.logout = mnAuthService.logout;
    vm.resetAutoFailOverCount = resetAutoFailOverCount;
    vm.isProgressBarClosed = true;
    vm.areThereMoreThenTwoRunningTasks = areThereMoreThenTwoRunningTasks;
    vm.toggleProgressBar = toggleProgressBar;
    vm.filterTasks = filterTasks;

    vm.pluggableUiConfigs = mnPluggableUiRegistry.getConfigs();
    vm.showAboutDialog = mnAboutDialogService.showAboutDialog;

    activate();

    function areThereMoreThenTwoRunningTasks() {
      return vm.tasks && vm.tasks.running.length > 1;
    }

    function toggleProgressBar() {
      vm.isProgressBarClosed = !vm.isProgressBarClosed;
    }

    function filterTasks(runningTasks) {
      return _.filter(runningTasks, formatProgressMessageFilter);
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

      new mnEtagPoller($scope, function (previous) {
        return mnPoolDefault.get({
          etag: previous ? previous.etag : "",
          waitChange: 10000
        }, false);
      }).subscribe(function (resp, previous) {
        vm.tabName = resp.clusterName;

        var version = parseVersionFilter(pools.implementationVersion);
        $rootScope.mnTitle = (version ? '(' + version[0] + ')' : '') + (vm.tabName ? '-' + vm.tabName : '');

        if (previous && previous.tasks.uri != resp.tasks.uri) {
          $rootScope.$broadcast("taskUriChanged");
        }
      })
      .cancelOnScopeDestroy()
      .cycle();

      $rootScope.$on("taskUriChanged", runTasks);
      runTasks();

      var poller;
      function runTasks() {
        poller && poller.stop();
        poller = new mnPoller($scope, mnTasksDetails.get)
          .subscribe("tasks", vm)
          .keepIn("app.admin", vm)
          .cancelOnScopeDestroy()
          .cycle();
      }
    }
  }
})();
