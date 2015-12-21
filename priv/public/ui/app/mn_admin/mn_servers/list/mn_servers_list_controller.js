(function () {
  "use strict";

  angular
    .module("mnServers")
    .controller("mnServersListController", mnServersListController);

  function mnServersListController($scope, $state, $rootScope, $uibModal, mnServersService, mnPoolDefault, mnSortableTable, $q, mnMemoryQuotaService, mnGsiService) {
    var vm = this;
    vm.sortableTableProperties = mnSortableTable.get();
    vm.isReAddPossible = isReAddPossible;
    vm.mnPoolDefault = mnPoolDefault.latestValue();

    vm.isNodeUnhealthy = isNodeUnhealthy;
    vm.showInactiveNodeHostname = showInactiveNodeHostname;
    vm.showActiveNodeHostname = showActiveNodeHostname;
    vm.showPendingRecoveryControls = showPendingRecoveryControls;
    vm.showPendingRemovalControls = showPendingRemovalControls;
    vm.showPendingAddControls = showPendingAddControls;
    vm.showFailedOverControls = showFailedOverControls;
    vm.isLastActiveData = isLastActiveData;
    vm.isDataDiskUsageAvailable = isDataDiskUsageAvailable;
    vm.couchDataSize = couchDataSize;
    vm.couchDiskUsage = couchDiskUsage;
    vm.getRebalanceProgress = getRebalanceProgress;
    vm.disableRemoveBtn = disableRemoveBtn;
    vm.isFailOverDisabled = isFailOverDisabled;
    vm.showRebalanceProgressPerItem = showRebalanceProgressPerItem;

    vm.getRamUsageConf = getRamUsageConf;
    vm.getSwapUsageConf = getSwapUsageConf;
    vm.getCpuUsageConf = getCpuUsageConf;

    vm.cancelEjectServer = cancelEjectServer;
    vm.cancelFailOverNode = cancelFailOverNode;
    vm.reAddNode = reAddNode;
    vm.failOverNode = failOverNode;
    vm.ejectServer = ejectServer;

    $scope.$watch("serversCtl.state", function (state) {
      vm.state = state;
    });

    var ramUsageConf = {};
    var swapUsageConf = {};
    var cpuUsageConf = {};

    activate();

    function showRebalanceProgressPerItem() {
      return vm.state.tasks.inRebalance && vm.state.tasks.tasksRebalance.status === 'running';
    }
    function isReAddPossible(node) {
      return isNodeInactiveFaied(node) && !isNodeUnhealthy(node) && !vm.mnPoolDefault.value.isROAdminCreds;
    }
    function showPendingRecoveryControls(node) {
      return !vm.state.tasks.inRebalance && isNodeInactiveAdded(node) && node.recoveryType !== 'none'
    }
    function showInactiveNodeHostname(node) {
      return isNodeInactiveFaied(node) && !isNodeUnhealthy(node);
    }
    function showActiveNodeHostname(node) {
      return !isNodeInactiveFaied(node) && !isNodeUnhealthy(node);
    }
    function showPendingAddControls(node) {
      return !vm.state.tasks.inRebalance && isNodeInactiveAdded(node) && node.recoveryType === 'none';
    }

    function getRamUsageConf(node) {
      var total = node.memoryTotal;
      var free = node.memoryFree;
      var used = total - free;
      ramUsageConf.exist = (total > 0) && _.isFinite(free);
      ramUsageConf.height = used / total * 100;
      ramUsageConf.top = 105 - used / total * 100;
      ramUsageConf.value = used / total * 100;
      return ramUsageConf;
    }
    function getSwapUsageConf(node) {
      var swapTotal = node.systemStats.swap_total;
      var swapUsed = node.systemStats.swap_used;
      swapUsageConf.exist = swapTotal > 0 && _.isFinite(swapUsed);
      swapUsageConf.height = swapUsed / swapTotal * 100;
      swapUsageConf.top = 105 - (swapUsed / swapTotal * 100);
      swapUsageConf.value = (swapUsed / swapTotal) * 100;
      return swapUsageConf;
    }
    function getCpuUsageConf(node) {
      var cpuRate = node.systemStats.cpu_utilization_rate;
      cpuUsageConf.exist = _.isFinite(cpuRate);
      cpuUsageConf.height = Math.floor(cpuRate * 100) / 100;
      cpuUsageConf.top = 105 - (Math.floor(cpuRate * 100) / 100);
      cpuUsageConf.value = Math.floor(cpuRate * 100) / 100;
      return cpuUsageConf;
    }
    function isFailOverDisabled(node) {
      return isLastActiveData(node) || vm.state.tasks.inRecoveryMode;
    }
    function disableRemoveBtn(node) {
      return isLastActiveData(node) || isActiveUnhealthy(node) || vm.state.tasks.inRecoveryMode;
    }
    function showFailedOverControls(node) {
      return !vm.state.tasks.inRebalance && !isNodeInactiveAdded(node) && !node.pendingEject;
    }
    function showPendingRemovalControls(node) {
      return !vm.state.tasks.inRebalance && !isNodeInactiveAdded(node) && node.pendingEject;
    }
    function isNodeInactiveAdded(node) {
      return node.clusterMembership === 'inactiveAdded';
    }
    function isNodeUnhealthy(node) {
      return node.status === 'unhealthy';
    }
    function isNodeInactiveFaied(node) {
      return node.clusterMembership === 'inactiveFailed';
    }
    function isLastActiveData(node) {
      return vm.state.nodes.reallyActiveData.length === 1 && (node.services.indexOf("kv") > -1);
    }
    function couchDataSize(node) {
      return node.interestingStats['couch_docs_data_size'] + node.interestingStats['couch_views_data_size'] + node.interestingStats['couch_spatial_data_size'];
    }
    function couchDiskUsage(node) {
      return node.interestingStats['couch_docs_actual_disk_size'] + node.interestingStats['couch_views_actual_disk_size'] + node.interestingStats['couch_spatial_disk_size']
    }
    function isDataDiskUsageAvailable(node) {
      return !!(couchDataSize(node) || couchDiskUsage(node));
    }
    function getRebalanceProgress(node) {
      return vm.state.tasks.tasksRebalance.perNode && vm.state.tasks.tasksRebalance.perNode[node.otpNode]
           ? vm.state.tasks.tasksRebalance.perNode[node.otpNode].progress : 0 ;
    }
    function isActiveUnhealthy(node) {
      return $state.params.type === "active" && isNodeUnhealthy(node);
    }
    function ejectServer(node) {
      if (isNodeInactiveAdded(node)) {
        mnPromiseHelper(vm, mnServersService.ejectNode({otpNode: node.otpNode}))
          .showErrorsSensitiveSpinner()
          .broadcast("reloadServersPoller");
        return;
      }

      var promise = $q.all([
        mnGsiService.getIndexesState(),
        mnServersService.getNodes()
      ]).then(function (resp) {
        var nodes = resp[1];
        var indexStatus = resp[0];
        var warnings = {
          isLastIndex: mnMemoryQuotaService.isOnlyOneNodeWithService(nodes.allNodes, node.services, 'index'),
          isLastQuery: mnMemoryQuotaService.isOnlyOneNodeWithService(nodes.allNodes, node.services, 'n1ql'),
          isThereIndex: !!_.find(indexStatus.indexes, function (index) {
            return _.indexOf(index.hosts, node.hostname) > -1;
          }),
          isKv: _.indexOf(node.services, 'kv') > -1
        };
        if (_.some(_.values(warnings))) {
          $uibModal.open({
            templateUrl: 'app/mn_admin/mn_servers/eject_dialog/mn_servers_eject_dialog.html',
            controller: 'mnServersEjectDialogController as serversEjectDialogCtl',
            resolve: {
              warnings: function () {
                return warnings;
              },
              node: function () {
                return node;
              }
            }
          });
        } else {
          mnServersService.addToPendingEject(node);
          $scope.$broadcast("reloadServersPoller");
        }
      });

      mnPromiseHelper(vm, promise);
    }
    function failOverNode(node) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_servers/failover_dialog/mn_servers_failover_dialog.html',
        controller: 'mnServersFailOverDialogController as serversFailOverDialogCtl',
        resolve: {
          node: function () {
            return node;
          }
        }
      });
    }
    function reAddNode(type, otpNode) {
      mnPromiseHelper(vm, mnServersService.reAddNode({
        otpNode: otpNode,
        recoveryType: type
      }))
      .broadcast("reloadServersPoller")
      .showErrorsSensitiveSpinner();
    }
    function cancelFailOverNode(otpNode) {
      mnPromiseHelper(vm, mnServersService.cancelFailOverNode({
        otpNode: otpNode
      }))
      .broadcast("reloadServersPoller")
      .showErrorsSensitiveSpinner();
    }
    function cancelEjectServer(node) {
      mnServersService.removeFromPendingEject(node);
      $scope.$broadcast("reloadServersPoller");
    }

    function activate() {
      $rootScope.$broadcast("reloadServersPoller");
    }
  }
})();
