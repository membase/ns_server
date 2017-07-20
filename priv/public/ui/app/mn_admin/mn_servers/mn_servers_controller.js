(function () {
  "use strict";

  angular
    .module('mnServers', [
      'mnPoolDefault',
      'ui.router',
      'mnAutocompleteOff',
      'ui.bootstrap',
      'mnServersService',
      'mnHelper',
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
      'mnTasksDetails',
      'mnWarmupProgress',
      'mnElementCrane',
      'mnSearch'
    ])
    .controller('mnServersController', mnServersController)
    .filter("formatFailoverWarnings", formatFailoverWarnings);

  function formatFailoverWarnings() {
    return function (warning) {
      switch (warning) {
      case 'rebalanceNeeded': return 'Rebalance required, some data is not currently replicated.';
      case 'hardNodesNeeded': return 'At least two servers with the data service are required to provide replication.';
      case 'softNodesNeeded': return 'Additional active servers required to provide the desired number of replicas.';
      case 'softRebalanceNeeded': return 'Rebalance recommended, some data does not have the desired replicas configuration.';
      }
    };
  }

  function mnServersController($scope, $state, $uibModal, mnPoolDefault, mnPoller, mnServersService, mnHelper, mnGroupsService, mnPromiseHelper, mnPools, mnSettingsAutoFailoverService, mnTasksDetails, permissions, mnFormatServicesFilter) {
    var vm = this;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    vm.stopRebalance = stopRebalance;
    vm.onStopRecovery = onStopRecovery;
    vm.postRebalance = postRebalance;
    vm.addServer = addServer;
    vm.listFiter = listFiter;
    vm.filterField = "";
    vm.sortByGroup = sortByGroup

    function sortByGroup(node) {
      return vm.getGroupsByHostname[node.hostname] && vm.getGroupsByHostname[node.hostname].name;
    }


    activate();

    //filter by multiple strictly defined fields in the node
    //e.g filterField -> "apple 0.0.0.0 data"
    //will return all kv nodes which run on macos 0.0.0.0 host
    function listFiter(node) {
      if (vm.filterField === "") {
        return true;
      }

      var interestingFields = ["hostname", "status"];
      var l2 = interestingFields.length;
      var l3 = node.services.length;
      var i2;
      var i3;
      var searchFiled;
      var searchValue = vm.filterField.toLowerCase();
      var rv = false;

      //look in services
      loop3:
      for (i3 = 0; i3 < l3; i3++) {
        if (mnFormatServicesFilter(node.services[i3])
            .toLowerCase()
            .indexOf(searchValue) > -1) {
          rv = true;
          break loop3;
        }
      }

      //look in interestingFields
      loop2:
      for (i2 = 0; i2 < l2; i2++) {
        searchFiled = interestingFields[i2];
        if (node[searchFiled].toLowerCase().indexOf(searchValue) > -1) {
          rv = true;
          break loop2;
        }
      }

      //look in group name
      if (!rv && vm.getGroupsByHostname && vm.getGroupsByHostname[node.hostname] &&
          vm.getGroupsByHostname[node.hostname].name.toLowerCase().indexOf(searchValue) > -1) {
        rv = true;
      }

      return rv;
    }

    function activate() {
      mnHelper.initializeDetailsHashObserver(vm, 'openedServers', 'app.admin.servers.list');

      if (permissions.cluster.server_groups.read) {
        new mnPoller($scope, function () {
          return mnGroupsService.getGroupsByHostname();
        })
          .subscribe("getGroupsByHostname", vm)
          .reloadOnScopeEvent(["serverGroupsUriChanged", "reloadServersPoller"])
          .cycle();
      }

      new mnPoller($scope, function () {
        return mnServersService.getNodes();
      })
        .subscribe(function (nodes) {
          vm.showSpinner = false;
          vm.nodes = nodes;
        })
        .reloadOnScopeEvent(["mnPoolDefaultChanged", "reloadNodes"])
        .cycle();


      if (permissions.cluster.settings.read) {
        new mnPoller($scope, function () {
          return mnSettingsAutoFailoverService.getAutoFailoverSettings();
        })
          .setInterval(10000)
          .subscribe("autoFailoverSettings", vm)
          .reloadOnScopeEvent(["reloadServersPoller", "rebalanceFinished"])
          .cycle();
      }

      $scope.$on("reloadServersPoller", function () {
        vm.showSpinner = true;
      });
    }
    function addServer() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_servers/add_dialog/mn_servers_add_dialog.html',
        controller: 'mnServersAddDialogController as serversAddDialogCtl',
        resolve: {
          groups: function () {
            return mnPoolDefault.get().then(function (poolDefault) {
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
        .catchGlobalErrors()
        .showErrorsSensitiveSpinner();
    }
    function onStopRecovery() {
      mnPromiseHelper(vm, mnServersService.stopRecovery($scope.adminCtl.tasks.tasksRecovery.stopURI))
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
