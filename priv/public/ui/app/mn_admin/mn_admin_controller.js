(function () {
  "use strict";

  angular
    .module('mnAdmin')
    .controller('mnAdminController', mnAdminController);

  function mnAdminController($scope, $rootScope, $state, $uibModal, poolDefault, mnAboutDialogService, mnSettingsNotificationsService, mnPromiseHelper, pools, mnPoller, mnEtagPoller, mnAuthService, mnTasksDetails, mnPoolDefault, mnSettingsAutoFailoverService, formatProgressMessageFilter, parseVersionFilter, mnPluggableUiRegistry, mnPoorMansAlertsService, mnLostConnectionService) {
    var vm = this;
    vm.poolDefault = poolDefault;
    vm.launchpadId = pools.launchID;
    vm.logout = mnAuthService.logout;
    vm.resetAutoFailOverCount = resetAutoFailOverCount;
    vm.isProgressBarClosed = true;
    vm.areThereMoreThenTwoRunningTasks = areThereMoreThenTwoRunningTasks;
    vm.toggleProgressBar = toggleProgressBar;
    vm.filterTasks = filterTasks;

    vm.pluggableUiConfigs = mnPluggableUiRegistry.getConfigs();
    vm.showAboutDialog = mnAboutDialogService.showAboutDialog;

    vm.enableInternalSettings = $state.params.enableInternalSettings;
    vm.runInternalSettingsDialog = runInternalSettingsDialog;
    vm.lostConnState = mnLostConnectionService.getState();

    activate();

    function runInternalSettingsDialog() {
      $uibModal.open({
        templateUrl: "app/mn_admin/mn_internal_settings/mn_internal_settings.html",
        controller: "mnInternalSettingsController as internalSettingsCtl"
      });
    }

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
      mnPromiseHelper(vm, mnSettingsAutoFailoverService.resetAutoFailOverCount({group: "global"}))
        .showSpinner('resetQuotaLoading')
        .catchGlobalErrors('Unable to reset the auto-failover quota!')
        .reloadState();
    }

    function activate() {
      mnPromiseHelper(vm, mnSettingsNotificationsService.maybeCheckUpdates({group: "global"}))
        .applyToScope("updates")
        .onSuccess(function (updates) {
          if (updates.sendStats) {
            mnPromiseHelper(vm, mnSettingsNotificationsService.buildPhoneHomeThingy({group: "global"}))
              .applyToScope("launchpadSource")
          }
        });

      new mnEtagPoller($scope, function (previous) {
        return mnPoolDefault.get({
          etag: previous ? previous.etag : "",
          waitChange: 10000
        }, {group: "global"});
      }).subscribe(function (resp, previous) {
        vm.tabName = resp.clusterName;

        if (!_.isEqual(resp.alerts, (previous || {}).alerts)) {
          mnPoorMansAlertsService.maybeShowAlerts(resp);
        }

        var version = parseVersionFilter(pools.implementationVersion);
        $rootScope.mnTitle = (version ? '(' + version[0] + ')' : '') + (vm.tabName ? '-' + vm.tabName : '');

        if (previous && previous.tasks.uri != resp.tasks.uri) {
          $rootScope.$broadcast("taskUriChanged");
        }
      })
      .cycle();

      var tasksPoller = new mnPoller($scope, function () {
        return mnTasksDetails.get({group: "global"});
      })
      .subscribe("tasks", vm)
      .cycle();

      $scope.$on("taskUriChanged", function () {
        tasksPoller.reload();
      });
    }
  }
})();
