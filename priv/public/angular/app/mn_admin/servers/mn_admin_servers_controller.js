angular.module('mnAdminServers').controller('mnAdminServersController',
  function ($scope, $state, $modal, $interval, $location, $stateParams, $timeout, mnPoolDefault, serversState, mnAdminSettingsAutoFailoverService, mnAdminServersService, mnHelper) {

    _.extend($scope, serversState);
    var updateServersCycle;
    (function updateServers() {
      mnAdminServersService.getServersState($stateParams.list).then(function (serversState) {
        _.extend($scope, serversState);
        updateServersCycle = $timeout(updateServers, serversState.recommendedRefreshPeriod);
      });
    })();

    $scope.$on('$destroy', function () {
      $timeout.cancel(updateServersCycle);
    });

    $scope.addServer = function () {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/servers/add_dialog/mn_admin_servers_add_dialog.html',
        controller: 'mnAdminServersAddDialogController',
        resolve: {
          groups: function () {
            return mnPoolDefault.get().then(function (poolDefault) {
              if (poolDefault.isGroupsAvailable) {
                return mnAdminServersService.getGroups();
              }
            });
          }
        }
      });
    };
    $scope.postRebalance = function () {
      mnAdminServersService.postRebalance($scope.allNodes).then(function () {
        $state.go('app.admin.servers', {list: 'active'});
        mnHelper.reloadState();
      });
    };
    $scope.onStopRecovery = function () {
      mnAdminServersService.stopRecovery($scope.tasks.tasksRecovery.stopURI).then(mnHelper.reloadState)
    };
    $scope.stopRebalance = function () {
      var request = mnAdminServersService.stopRebalance().then(
        mnHelper.reloadState,
        function (reps) {
          (reps.status === 400) && $modal.open({
            templateUrl: '/angular/app/mn_admin/servers/stop_rebalance_dialog/mn_admin_servers_stop_rebalance_dialog.html',
            controller: 'mnAdminServersEjectDialogController'
          });
      });
    };
    $scope.resetAutoFailOverCount = function () {
      mnAdminSettingsAutoFailoverService.resetAutoFailOverCount()
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


    function getOpenedServers() {
      return _.wrapToArray($location.search()['openedServers']);
    }
    $scope.isDetailsOpened = function (hostname) {
      return _.contains(getOpenedServers(), hostname);
    };
    $scope.toggleDetails = function (hostname) {
      var currentlyOpened = getOpenedServers();
      if ($scope.isDetailsOpened(hostname)) {
        $location.search('openedServers', _.difference(currentlyOpened, [hostname]));
      } else {
        currentlyOpened.push(hostname);
        $location.search('openedServers', currentlyOpened);
      }
    };

    $scope.ejectServer = function (node) {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/servers/eject_dialog/mn_admin_servers_eject_dialog.html',
        controller: 'mnAdminServersEjectDialogController',
        resolve: {
          node: function () {
            return node;
          }
        }
      });
    };
    $scope.failOverNode = function (node) {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/servers/failover_dialog/mn_admin_servers_failover_dialog.html',
        controller: 'mnAdminServersFailOverDialogController',
        resolve: {
          node: function () {
            return node;
          }
        }
      });
    };
    $scope.reAddNode = function (type, otpNode) {
      mnAdminServersService.reAddNode({
        otpNode: otpNode,
        recoveryType: type
      }).then(mnHelper.reloadState);
    };
    $scope.cancelFailOverNode = function (otpNode) {
      mnAdminServersService.cancelFailOverNode({
        otpNode: otpNode
      }).then(mnHelper.reloadState);
    };
    $scope.cancelEjectServer = function (node) {
      mnAdminServersService.removeFromPendingEject(node);
      mnHelper.reloadState();
    };

  });