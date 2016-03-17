(function () {
  "use strict";

  angular
    .module('mnServers', [
      'mnPoolDefault',
      'ui.router',
      'ui.bootstrap',
      'mnServersService',
      'mnHelper',
      'mnVerticalBar',
      'mnBarUsage',
      'mnServersListItemDetailsService',
      'mnFilters',
      'mnSortableTable',
      'mnServices',
      'mnSpinner',
      'ngMessages',
      'mnMemoryQuotaService',
      'mnGsiService',
      'mnPromiseHelper',
      'mnGroupsService',
      'mnStorageMode',
      'mnPoll',
      'mnFocus',
      'mnPools',
      'mnSettingsAutoFailoverService',
      'mnTasksDetails'
    ])
    .controller('mnServersController', mnServersController)
    .filter("formatFailoverWarnings", formatFailoverWarnings);

  function formatFailoverWarnings() {
    return function (warning) {
      switch (warning) {
        case 'rebalanceNeeded': return 'Rebalance required, some data is not currently replicated!';
        case 'hardNodesNeeded': return 'At least two servers with the data service are required to provide replication!';
        case 'softNodesNeeded': return 'Additional active servers required to provide the desired number of replicas!';
        case 'softRebalanceNeeded': return 'Rebalance recommended, some data does not have the desired replicas configuration!';
      }
    };
  }

  function mnServersController($scope, $state, $uibModal, mnPoolDefault, mnPoller, mnServersService, mnHelper, mnGroupsService, mnPromiseHelper, mnPools, mnSettingsAutoFailoverService, mnTasksDetails) {
    var vm = this;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    vm.stopRebalance = stopRebalance;
    vm.onStopRecovery = onStopRecovery;
    vm.postRebalance = postRebalance;
    vm.addServer = addServer;
    vm.mayRebalanceWithoutSampleLoading = mayRebalanceWithoutSampleLoading;

    activate();

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedServers', 'app.admin.servers.list');

      new mnPoller($scope, function () {
        return mnGroupsService.getGroupsByHostname();
      })
      .subscribe("getGroupsByHostname", vm)
      .reloadOnScopeEvent("reloadServersPoller", vm, "serverGroupsLoading");

      new mnPoller($scope, function () {
        return mnServersService.getNodes();
      })
      .subscribe("nodes", vm)
      .reloadOnScopeEvent("reloadServersPoller", vm, "nodesLoading");
      new mnPoller($scope, function () {
        return mnPoolDefault.getFresh();
      })
      .subscribe("poolDefault", vm)
      .reloadOnScopeEvent("reloadServersPoller", vm, "poolDefaultLoading");
      new mnPoller($scope, function () {
        return mnTasksDetails.get();
      })
      .subscribe("tasks", vm)
      .reloadOnScopeEvent("reloadServersPoller", vm, "tasksLoading");
      new mnPoller($scope, function () {
        return mnSettingsAutoFailoverService.getAutoFailoverSettings();
      })
      .subscribe("autoFailoverSettings", vm)
      .reloadOnScopeEvent("reloadServersPoller", vm, "autoFailoverSettingsLoading");
    }
    function mayRebalanceWithoutSampleLoading() {
      return (vm.poolDefault && !vm.poolDefault.rebalancing) &&
             (vm.tasks && !vm.tasks.inRecoveryMode) &&
             vm.nodes && (!!vm.nodes.pending.length || !vm.poolDefault.balanced) && !vm.nodes.unhealthyActive;
    }
    function addServer() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_servers/add_dialog/mn_servers_add_dialog.html',
        controller: 'mnServersAddDialogController as serversAddDialogCtl',
        resolve: {
          groups: function () {
            return mnPoolDefault.getFresh().then(function (poolDefault) {
              if (poolDefault.isGroupsAvailable) {
                return mnGroupsService.getGroups();
              }
            });
          }
        }
      });
    }
    function postRebalance() {
      mnPromiseHelper(vm, mnServersService.postRebalance(vm.nodes.allNodes))
        .onSuccess(function () {
          $state.go('app.admin.servers.list', {list: 'active'});
        })
        .broadcast("reloadServersPoller")
        .showErrorsSensitiveSpinner();
    }
    function onStopRecovery() {
      mnPromiseHelper(vm, mnServersService.stopRecovery(vm.tasks.tasksRecovery.stopURI))
        .broadcast("reloadServersPoller")
        .showErrorsSensitiveSpinner();
    }
    function stopRebalance() {
      mnPromiseHelper(vm, mnServersService.stopRebalance())
        .onSuccess(function (resp) {
          (resp === 400) && $uibModal.open({
            templateUrl: 'app/mn_admin/mn_servers/stop_rebalance_dialog/mn_servers_stop_rebalance_dialog.html',
            controller: 'mnServersStopRebalanceDialogController as serversStopRebalanceDialogCtl'
          });
        })
        .broadcast("reloadServersPoller")
        .showErrorsSensitiveSpinner();
    }
  }
})();

