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
      'mnPoll',
      'mnFocus',
      'mnPools'
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

  function mnServersController($scope, $state, $uibModal, mnPoolDefault, mnPoller, mnServersService, mnHelper, mnGroupsService, mnPromiseHelper, mnPools) {
    var vm = this;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    vm.isServerGroupsDisabled = isServerGroupsDisabled;
    vm.isAddServerDisabled = isAddServerDisabled;
    vm.isRebalanceDisabled = isRebalanceDisabled;
    vm.stopRebalanceDisabled = stopRebalanceDisabled;
    vm.stopRecoveryDisabled = stopRecoveryDisabled;

    vm.stopRebalance = stopRebalance;
    vm.onStopRecovery = onStopRecovery;
    vm.postRebalance = postRebalance;
    vm.addServer = addServer;

    activate();

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedServers', 'app.admin.servers.list');

      var poller = new mnPoller($scope, function () {
          return mnServersService.getServersState($state.params.list);
        })
        .subscribe("state", vm)
        .reloadOnScopeEvent("reloadServersPoller", vm);
    }
    function isServerGroupsDisabled() {
      return !vm.state || !vm.state.isGroupsAvailable || vm.mnPoolDefault.value.isROAdminCreds || !vm.mnPoolDefault.value.isEnterprise;
    }
    function isAddServerDisabled() {
      return !vm.state || vm.state.rebalancing || vm.mnPoolDefault.value.isROAdminCreds;
    }
    function isRebalanceDisabled() {
      return !vm.state || !vm.state.mayRebalance || vm.mnPoolDefault.value.isROAdminCreds;
    }
    function stopRebalanceDisabled() {
      return !vm.state || !vm.state.tasks.inRebalance || vm.mnPoolDefault.value.isROAdminCreds;
    }
    function stopRecoveryDisabled() {
      return !vm.state || !vm.state.tasks.inRecoveryMode || vm.mnPoolDefault.value.isROAdminCreds;
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
      mnPromiseHelper(vm, mnServersService.postRebalance(vm.state.nodes.allNodes))
        .onSuccess(function () {
          $state.go('app.admin.servers.list', {list: 'active'});
        })
        .broadcast("reloadServersPoller")
        .showErrorsSensitiveSpinner();
    }
    function onStopRecovery() {
      mnPromiseHelper(vm, mnServersService.stopRecovery(vm.state.tasks.tasksRecovery.stopURI))
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

