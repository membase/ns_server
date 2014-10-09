angular.module('mnAdminServers').controller('mnAdminServersController',
  function ($scope, $timeout, $stateParams, mnAdminServersService, mnAdminService, mnAdminTasksService, mnDialogService, $state, mnAdminServersService, mnAdminServersListItemService, mnAdminSettingsAutoFailoverService) {

    $scope.addServer = function () {
      mnDialogService.open({
        template: '/angular/app/mn_admin/servers/add_dialog/mn_admin_servers_add_dialog.html',
        scope: $scope
      });
    };

    $scope.onRebalance = function () {
      mnAdminServersService.postAndReload(mnAdminService.model.details.controllers.rebalance.uri, {
        knownNodes: _.pluck(mnAdminService.model.nodes.allNodes, 'otpNode').join(','),
        ejectedNodes: _.pluck(mnAdminServersListItemService.model.pendingEject, 'otpNode').join(',')
      }).success(function () {
        $state.go('admin.servers.list', {list: 'active'});
      });
    };

    $scope.onStopRecovery = function () {
      mnAdminServersService.postAndReload(mnAdminTasksService.model.stopRecoveryURI);
    };

    function displayRequestFailedNotice(data, status) {
      (status != 400) //&& displayNotice("Request failed. Check logs.", true);
    }

    function displayAdditionalConfiramtion(data, status) {
      (status == 400) && mnDialogService.open({
        template: '/angular/app/mn_admin/servers/stop_rebalance_dialog/mn_admin_servers_stop_rebalance_dialog.html',
        scope: $scope
      });
    }

    function closeStopRebalanceDialog() {
      $scope.mnDialogStopRebalanceDialogLoading = false;
      mnDialogService.removeLastOpened();
    }

    $scope.onStopRebalance = function () {
      var url = mnAdminService.model.details.stopRebalanceUri;
      var isAlreadyOpened = !!mnDialogService.getLastOpened();

      var request = mnAdminServersService.onStopRebalance(url).error(displayRequestFailedNotice);

      if (isAlreadyOpened) {
        $scope.mnDialogStopRebalanceDialogLoading = true;
        request.success(closeStopRebalanceDialog);
      } else {
        request.error(displayAdditionalConfiramtion);
      }
    };

    function maybeRebalanceError(task) {
      if (!task) {
        return;
      }
      if (task.status !== 'running') {
        if (mnAdminServersService.model.sawRebalanceRunning && task.errorMessage) {
          mnAdminServersService.model.sawRebalanceRunning = false;
          // displayNotice(task.errorMessage, true);
        }
      }
      mnAdminServersService.model.sawRebalanceRunning = true;
    }

    $scope.resetAutoFailOverCount = function () {
      mnAdminSettingsAutoFailoverService.resetAutoFailOverCount()
        .success(function () {
          $scope.isResetAutoFailOverCountSuccess = true;
          $timeout(function () {
            $scope.isAutoFailOverCountAvailable = false;
            $scope.isResetAutoFailOverCountSuccess = false;
          }, 3000);
        }).error(function () {
          // genericDialog({
          //   buttons: {ok: true},
          //   header: 'Unable to reset the auto-failover quota',
          //   textHTML: 'An error occured, auto-failover quota was not reset.'
          // });
        });
    };

    $scope.$watch(function () {
      return {
        nodes: mnAdminService.model.nodes,
        tasksRecovery: mnAdminTasksService.model.inRecoveryMode,
        isLoadingSamples: mnAdminTasksService.model.isLoadingSamples,
        mayRebalanceWithoutSampleLoading: mnAdminServersService.model.mayRebalanceWithoutSampleLoading
      };
    }, function () {
      mnAdminSettingsAutoFailoverService.getAutoFailoverSettings().success(function (data) {
        $scope.isAutoFailOverCountAvailable = !!(data && data.count > 0);
      });
    }, true);

    $scope.$watch('mnAdminTasksServiceModel.tasksRebalance', maybeRebalanceError);

    $scope.$watch('mnAdminServiceModel.details.failoverWarnings', mnAdminServersService.populateFailoverWarningsModel);

    $scope.$watch(function () {
      if (!mnAdminService.model.details || !mnAdminService.model.nodes) {
        return;
      }

      return {
        inRecoveryMode: mnAdminTasksService.model.inRecoveryMode,
        isLoadingSamples: mnAdminTasksService.model.isLoadingSamples,
        rebalanceStatus: mnAdminService.model.details.rebalanceStatus,
        balanced: mnAdminService.model.details.balanced,
        unhealthyActiveNodes: mnAdminService.model.nodes.unhealthyActive,
        pendingNodes: mnAdminService.model.nodes.pending
      };
    }, mnAdminServersService.populateRebalanceModel, true);

    $scope.$watch(function () {
      if (!mnAdminService.model.nodes) {
        return;
      }
      return {
        progress: mnAdminTasksService.model.tasksRebalance,
        nodes: mnAdminService.model.nodes.allNodes
      };
    }, mnAdminServersService.populatePerNodeRepalanceProgress, true);
  });