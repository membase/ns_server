angular.module('mnServers', [
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
  'mnMemoryQuotaService',
  'mnIndexesService',
  'mnPromiseHelper',
  'mnGroupsService',
  'mnPoll',
  'mnPools'
]).controller('mnServersController',
  function ($scope, $state, $uibModal, $q, $interval, mnMemoryQuotaService, mnIndexesService, $stateParams, $timeout, mnPoolDefault, mnPoll, mnServersService, mnHelper, mnGroupsService, mnPromiseHelper, mnPools) {

    $scope.mnPoolDefault = mnPoolDefault.latestValue();

    //hack for avoiding access to $parent scope from child scope via propery "$parent"
    //should be removed after implementation of Controller As syntax
    $scope.mnServersController = $scope;

    $scope.isServerGroupsDisabled = function () {
      return !$scope.mnServersState || !$scope.mnServersState.isGroupsAvailable || $scope.mnPoolDefault.value.isROAdminCreds || !$scope.mnPoolDefault.value.isEnterprise;
    };
    $scope.isAddServerDisabled = function () {
      return !$scope.mnServersState || $scope.mnServersState.rebalancing || $scope.mnPoolDefault.value.isROAdminCreds;
    };
    $scope.isRebalanceDisabled = function () {
      return !$scope.mnServersState || !$scope.mnServersState.mayRebalance || $scope.mnPoolDefault.value.isROAdminCreds;
    };
    $scope.stopRebalanceDisabled = function () {
      return !$scope.mnServersState || !$scope.mnServersState.tasks.inRebalance || $scope.mnPoolDefault.value.isROAdminCreds;
    };
    $scope.stopRecoveryDisabled = function () {
      return !$scope.mnServersState || !$scope.mnServersState.tasks.inRecoveryMode || $scope.mnPoolDefault.value.isROAdminCreds;
    };

    mnPoll
      .start($scope, function () {
        return mnServersService.getServersState($stateParams.list);
      })
      .subscribe("mnServersState")
      .keepIn("app.admin.servers")
      .cancelOnScopeDestroy()
      .cycle();

    $scope.addServer = function () {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_servers/add_dialog/mn_servers_add_dialog.html',
        controller: 'mnServersAddDialogController',
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
    };
    $scope.postRebalance = function () {
      mnPromiseHelper($scope, mnServersService.postRebalance($scope.mnServersState.allNodes))
        .onSuccess(function () {
          $state.go('app.admin.servers', {list: 'active'});
          $scope.viewLoading = true;
        })
        .reloadState()
        .cancelOnScopeDestroy();
    };
    $scope.onStopRecovery = function () {
      mnPromiseHelper($scope, mnServersService.stopRecovery($scope.tasks.tasksRecovery.stopURI))
        .reloadState()
        .cancelOnScopeDestroy();
    };
    $scope.stopRebalance = function () {
      mnPromiseHelper($scope, mnServersService.stopRebalance())
        .cancelOnScopeDestroy()
        .reloadState()
        .getPromise()
        .then(function (reps) {
          (reps.status === 400) && $uibModal.open({
            templateUrl: 'app/mn_admin/mn_servers/stop_rebalance_dialog/mn_servers_stop_rebalance_dialog.html',
            controller: 'mnServersStopRebalanceDialogController'
          });
        });
    };

    mnHelper.initializeDetailsHashObserver($scope, 'openedServers', 'app.admin.servers');

    $scope.ejectServer = function (node) {
      if (node.isNodeInactiveAdded) {
        mnPromiseHelper($scope, mnServersService.ejectNode({otpNode: node.otpNode}))
          .showSpinner()
          .reloadState()
          .cancelOnScopeDestroy();
        return;
      }

      var promise = $q.all([
        mnIndexesService.getIndexesState(),
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
            controller: 'mnServersEjectDialogController',
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
          $scope.viewLoading = true;
          mnHelper.reloadState();
        }
      });

      mnPromiseHelper($scope, promise).cancelOnScopeDestroy();
    };
    $scope.failOverNode = function (node) {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_servers/failover_dialog/mn_servers_failover_dialog.html',
        controller: 'mnServersFailOverDialogController',
        resolve: {
          node: function () {
            return node;
          }
        }
      });
    };
    $scope.reAddNode = function (type, otpNode) {
      mnPromiseHelper($scope, mnServersService.reAddNode({
        otpNode: otpNode,
        recoveryType: type
      }))
      .reloadState()
      .cancelOnScopeDestroy();
    };
    $scope.cancelFailOverNode = function (otpNode) {
      mnPromiseHelper($scope, mnServersService.cancelFailOverNode({
        otpNode: otpNode
      }))
      .reloadState()
      .cancelOnScopeDestroy();
    };
    $scope.cancelEjectServer = function (node) {
      mnServersService.removeFromPendingEject(node);
      mnHelper.reloadState();
    };

  }).filter("formatFailoverWarnings", function () {
    return function (warning) {
      switch (warning) {
        case 'rebalanceNeeded': return 'Rebalance required, some data is not currently replicated!';
        case 'hardNodesNeeded': return 'At least two servers with the data service are required to provide replication!';
        case 'softNodesNeeded': return 'Additional active servers required to provide the desired number of replicas!';
        case 'softRebalanceNeeded': return 'Rebalance recommended, some data does not have the desired replicas configuration!';
      }
    };
  });

