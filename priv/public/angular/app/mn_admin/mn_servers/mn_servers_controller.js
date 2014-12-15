angular.module('mnServers').controller('mnServersController',
  function ($scope, $state, $modal, $interval, $stateParams, $timeout, mnPoolDefault, serversState, mnSettingsAutoFailoverService, mnServersService, mnHelper) {

    _.extend($scope, serversState);
    var updateServersCycle;
    (function updateServers() {
      mnServersService.getServersState($stateParams.list).then(function (serversState) {
        _.extend($scope, serversState);
        updateServersCycle = $timeout(updateServers, serversState.recommendedRefreshPeriod);
      });
    })();

    $scope.$on('$destroy', function () {
      $timeout.cancel(updateServersCycle);
    });

    $scope.addServer = function () {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/mn_servers/add_dialog/mn_servers_add_dialog.html',
        controller: 'mnServersAddDialogController',
        resolve: {
          groups: function () {
            return mnPoolDefault.get().then(function (poolDefault) {
              if (poolDefault.isGroupsAvailable) {
                return mnServersService.getGroups();
              }
            });
          }
        }
      });
    };
    $scope.postRebalance = function () {
      mnServersService.postRebalance($scope.allNodes).then(function () {
        $state.go('app.admin.servers', {list: 'active'});
        mnHelper.reloadState();
      });
    };
    $scope.onStopRecovery = function () {
      mnServersService.stopRecovery($scope.tasks.tasksRecovery.stopURI).then(mnHelper.reloadState)
    };
    $scope.stopRebalance = function () {
      var request = mnServersService.stopRebalance().then(
        mnHelper.reloadState,
        function (reps) {
          (reps.status === 400) && $modal.open({
            templateUrl: '/angular/app/mn_admin/mn_servers/stop_rebalance_dialog/mn_servers_stop_rebalance_dialog.html',
            controller: 'mnServersEjectDialogController'
          });
      });
    };
    $scope.resetAutoFailOverCount = function () {
      mnSettingsAutoFailoverService.resetAutoFailOverCount()
        .then(function () {
          $scope.isResetAutoFailOverCountSuccess = true;
          $timeout(function () {
            $scope.isAutoFailOverCountAvailable = false;
            $scope.isResetAutoFailOverCountSuccess = false;
          }, 3000);
        }, function () {
          $scope.showAutoFailOverWarningMessage = true
        });
    };
    $scope.formatServices = function (services) {
      return _(services).map(function (service) {
        switch (service) {
          case 'kv': return 'Data';
          case 'n1ql': return 'N1QL';
          case 'moxi': return 'Moxi';
        }
      }).value();
    }

    mnHelper.initializeDetailsHashObserver($scope, 'openedServers');

    $scope.ejectServer = function (node) {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/mn_servers/eject_dialog/mn_servers_eject_dialog.html',
        controller: 'mnServersEjectDialogController',
        resolve: {
          node: function () {
            return node;
          }
        }
      });
    };
    $scope.failOverNode = function (node) {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/mn_servers/failover_dialog/mn_servers_failover_dialog.html',
        controller: 'mnServersFailOverDialogController',
        resolve: {
          node: function () {
            return node;
          }
        }
      });
    };
    $scope.reAddNode = function (type, otpNode) {
      mnServersService.reAddNode({
        otpNode: otpNode,
        recoveryType: type
      }).then(mnHelper.reloadState);
    };
    $scope.cancelFailOverNode = function (otpNode) {
      mnServersService.cancelFailOverNode({
        otpNode: otpNode
      }).then(mnHelper.reloadState);
    };
    $scope.cancelEjectServer = function (node) {
      mnServersService.removeFromPendingEject(node);
      mnHelper.reloadState();
    };

  });