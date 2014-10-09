angular.module('mnAdminServers').controller('mnAdminServersListItemController',
  function ($scope, $state, $location, $stateParams, mnAdminService, mnDialogService, mnAdminServersService, mnAdminServersFailOverDialogService, mnAdminServersListItemService) {

    function getFromStats(value) {
      return $scope.node.interestingStats[value];
    }
    function getOpenedServers() {
      return _.wrapToArray($location.search()['openedServers']);
    }
    function applyToScope(name) {
      return function (data) {
        $scope[name] = data;
      }
    }


    $scope.$watch(function () {
      return _.formatQuantity(getFromStats('couch_docs_data_size') + getFromStats('couch_views_data_size'));
    }, applyToScope('couchDataSize'));

    $scope.$watch(function () {
      return _.formatQuantity(getFromStats('couch_docs_actual_disk_size') + getFromStats('couch_views_actual_disk_size'));
    }, applyToScope('couchDiskUsage'));

    $scope.$watch(function () {
      return _.formatQuantity(getFromStats('curr_items') || 0, 1000, ' ');
    }, applyToScope('currItems'));

    $scope.$watch(function () {
      return _.formatQuantity(getFromStats('vb_replica_curr_items') || 0, 1000, ' ');
    }, applyToScope('currVbItems'));

    $scope.$watch(function () {
      return !!($scope.couchDataSize && $scope.couchDiskUsage);
    }, applyToScope('isDataDiskUsageAvailable'));

    $scope.$watch(function () {
      return $scope.node.status === 'unhealthy';
    }, applyToScope('isNodeUnhealthy'));

    $scope.$watch(function () {
      return $scope.node.clusterMembership === 'inactiveFailed';
    }, applyToScope('isNodeInactiveFaied'));

    $scope.$watch(function () {
      return $scope.node.clusterMembership == 'inactiveAdded';
    }, applyToScope('isNodeInactiveAdded'));

    $scope.$watch(function () {
      return $scope.isNodeInactiveFaied && !$scope.isNodeUnhealthy;
    }, applyToScope('isReAddPossible'));

    $scope.$watch(function () {
      return _.contains(getOpenedServers(), $scope.node.hostname);
    }, applyToScope('isDetailsOpened'));

    $scope.$watch(function () {
      return mnAdminService.model.nodes.reallyActive.length === 1;
    }, applyToScope('isLastActive'));

    $scope.$watch(function () {
      return $stateParams.list === "active" && $scope.isNodeUnhealthy;
    }, applyToScope('isActiveUnhealthy'));

    $scope.$watch(function () {
      return _.makeSafeForCSS($scope.node.otpNode);
    }, applyToScope('safeNodeOtpNode'));

    $scope.$watch(function () {
      return _.stripPortHTML($scope.node.hostname, $scope.nodesList);
    }, applyToScope('strippedPort'));


    $scope.$watch(function () {
      var total = $scope.node.memoryTotal;
      var free = $scope.node.memoryFree;

      return {
        exist: (total > 0) && _.isFinite(free),
        height: (total - free) / total * 100,
        top: 105 - ((total - free) / total * 100),
        value: _.truncateTo3Digits((total - free) / total * 100)
      };
    }, applyToScope('ramUsageConf'), true);

    $scope.$watch(function () {
      var systemStats = $scope.node.systemStats;
      var swapTotal = systemStats.swap_total;
      var swapUsed = systemStats.swap_used;

      return {
        exist: swapTotal > 0 && _.isFinite(swapUsed),
        height: swapUsed / swapTotal * 100,
        top: 105 - (swapUsed / swapTotal * 100),
        value: _.truncateTo3Digits((swapUsed / swapTotal) * 100)
      };
    }, applyToScope('swapUsageConf'), true);

    $scope.$watch(function () {
      var cpuRate = $scope.node.systemStats.cpu_utilization_rate;

      return {
        exist: _.isFinite(cpuRate),
        height: Math.floor(cpuRate * 100) / 100,
        top: 105 - (Math.floor(cpuRate * 100) / 100),
        value: _.truncateTo3Digits(Math.floor(cpuRate * 100) / 100)
      };
    }, applyToScope('cpuUsageConf'),  true);

    $scope.ejectServer = function () {
      mnDialogService.open({
        template: '/angular/app/mn_admin/servers/eject_dialog/mn_admin_servers_eject_dialog.html',
        scope: $scope
      });
    };

    $scope.doEjectServer = function () {
      if ($scope.node.clusterMembership == 'inactiveAdded') {
        var url = mnAdminService.model.details.controllers.ejectNode.uri;
        mnAdminServersService.postAndReload(url, {otpNode: $scope.node.otpNode});
      } else {
        mnAdminServersListItemService.addToPendingEject($scope.node);
      }
      mnDialogService.removeLastOpened();
    };

    $scope.reAddNode = function (type) {
      var url = mnAdminService.model.details.controllers.setRecoveryType.uri;
      mnAdminServersService.postAndReload(url, {otpNode: $scope.node.otpNode, recoveryType: type});
    };

    $scope.cancelFailOverNode = function () {
      var url = mnAdminService.model.details.controllers.reFailOver.uri;
      mnAdminServersService.postAndReload(url, {otpNode: $scope.node.otpNode});
    };

    $scope.failOverNode = function () {
      mnDialogService.open({
        template: '/angular/app/mn_admin/servers/failover_dialog/mn_admin_servers_failover_dialog.html',
        scope: $scope
      });
    };

    $scope.cancelEjectServer = function () {
      mnAdminServersListItemService.removeFromPendingEject($scope.node);
    };

    $scope.toggleDetails = function () {
      var currentlyOpened = getOpenedServers();
      if ($scope.isDetailsOpened) {
        $location.search('openedServers', _.difference(currentlyOpened, [$scope.node.hostname]));
      } else {
        currentlyOpened.push($scope.node.hostname);
        $location.search('openedServers', currentlyOpened);
      }
    }

});