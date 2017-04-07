(function () {
  "use strict";

  angular
    .module('mnAdmin')
    .controller('mnAdminController', mnAdminController);

  function mnAdminController($scope, $rootScope, $state, $uibModal, mnAlertsService, poolDefault, mnSettingsNotificationsService, mnPromiseHelper, pools, mnPoller, mnEtagPoller, mnAuthService, mnTasksDetails, mnPoolDefault, mnSettingsAutoFailoverService, formatProgressMessageFilter, mnPrettyVersionFilter, mnPoorMansAlertsService, mnLostConnectionService, mnPermissions, mnPools, mnMemoryQuotaService, mnResetPasswordDialogService, whoami) {
    var vm = this;
    vm.poolDefault = poolDefault;
    vm.launchpadId = pools.launchID;
    vm.logout = mnAuthService.logout;
    vm.resetAutoFailOverCount = resetAutoFailOverCount;
    vm.isProgressBarClosed = true;
    vm.toggleProgressBar = toggleProgressBar;
    vm.filterTasks = filterTasks;
    vm.showResetPasswordDialog = showResetPasswordDialog;

    vm.user = whoami;

    vm.$state = $state

    vm.enableInternalSettings = $state.params.enableInternalSettings;
    vm.runInternalSettingsDialog = runInternalSettingsDialog;
    vm.lostConnState = mnLostConnectionService.getState();

    vm.alerts = mnAlertsService.alerts;
    vm.closeAlert = mnAlertsService.removeItem;

    $rootScope.rbac = mnPermissions.export;
    $rootScope.poolDefault = mnPoolDefault.export;
    $rootScope.pools = mnPools.export;

    activate();

    function showResetPasswordDialog() {
      vm.showUserDropdownMenu = false;
      mnResetPasswordDialogService.showDialog(whoami);
    }

    function runInternalSettingsDialog() {
      $uibModal.open({
        templateUrl: "app/mn_admin/mn_internal_settings/mn_internal_settings.html",
        controller: "mnInternalSettingsController as internalSettingsCtl"
      });
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
      if (mnPermissions.export.cluster.settings.read) {
        mnPromiseHelper(vm, mnSettingsNotificationsService.maybeCheckUpdates({group: "global"}))
          .applyToScope("updates")
          .onSuccess(function (updates) {
            if (updates.sendStats) {
              mnPromiseHelper(vm, mnSettingsNotificationsService.buildPhoneHomeThingy({group: "global"}))
                .applyToScope("launchpadSource")
            }
          });
      }

      var etagPoller = new mnEtagPoller($scope, function (previous) {
        return mnPoolDefault.get({
          etag: previous ? previous.etag : "",
          waitChange: $state.current.name === "app.admin.overview" ? 3000 : 10000
        }, {group: "global"});
      }).subscribe(function (resp, previous) {
        if (!_.isEqual(resp, previous)) {
          $rootScope.$broadcast("mnPoolDefaultChanged");
        }

        vm.tabName = resp.clusterName;

        if (previous && !_.isEqual(resp.nodes, previous.nodes)) {
          $rootScope.$broadcast("nodesChanged");
        }

        if (previous && previous.buckets.uri !== resp.buckets.uri) {
          $rootScope.$broadcast("bucketUriChanged");
        }

        if (previous && previous.serverGroupsUri !== resp.serverGroupsUri) {
          $rootScope.$broadcast("serverGroupsUriChanged");
        }

        if (previous && previous.indexStatusURI !== resp.indexStatusURI) {
          $rootScope.$broadcast("indexStatusURIChanged");
        }

        if (!_.isEqual(resp.alerts, (previous || {}).alerts)) {
          mnPoorMansAlertsService.maybeShowAlerts(resp);
        }

        var version = mnPrettyVersionFilter(pools.implementationVersion);
        $rootScope.mnTitle = "Couchbase Console " + (version ? version : '') + (vm.tabName ? ' - ' + vm.tabName : '');

        if (previous && previous.tasks.uri != resp.tasks.uri) {
          $rootScope.$broadcast("reloadTasksPoller");
        }

        if (previous && previous.checkPermissionsURI != resp.checkPermissionsURI) {
          mnPermissions.check();
        }
      })
      .cycle();

      if (mnPermissions.export.cluster.tasks.read) {
        var tasksPoller = new mnPoller($scope, function () {
          return mnTasksDetails.getFresh({group: "global"});
        })
            .setInterval(function (result) {
              return (_.chain(result.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
            })
            .subscribe(function (tasks, prevTask) {
              vm.showTasksSpinner = false;
              if (!_.isEqual(tasks, prevTask)) {
                $rootScope.$broadcast("mnTasksDetailsChanged");
              }
              var isRebalanceFinished =
                  tasks.tasksRebalance && tasks.tasksRebalance.status !== 'running' &&
                  prevTask && prevTask.tasksRebalance && prevTask.tasksRebalance.status === "running";
              if (isRebalanceFinished) {
                $rootScope.$broadcast("rebalanceFinished");
              }

              if (!vm.isProgressBarClosed &&
                  !filterTasks(tasks.running).length &&
                  prevTask && filterTasks(prevTask.running).length) {
                vm.isProgressBarClosed = true;
              }

                if (tasks.inRebalance) {
                  if (!prevTask) {
                    vm.isProgressBarClosed = false;
                  } else {
                    if (!prevTask.tasksRebalance ||
                        prevTask.tasksRebalance.status !== "running") {
                      vm.isProgressBarClosed = false;
                    }
                  }
                }

              if (tasks.tasksRebalance.errorMessage && mnAlertsService.isNewAlert({id: tasks.tasksRebalance.statusId})) {
                mnAlertsService.setAlert("error", tasks.tasksRebalance.errorMessage, null, tasks.tasksRebalance.statusId);
              }
              vm.tasks = tasks;
            }, vm)
            .cycle();
      }

      $scope.$on("reloadTasksPoller", function (event, params) {
        if (!params || !params.doNotShowSpinner) {
          vm.showTasksSpinner = true;
        }
        tasksPoller.reload(true);
      });

      $scope.$on("reloadPoolDefaultPoller", function () {
        mnPoolDefault.clearCache();
        etagPoller.reload();
      });

      $scope.$on("maybeShowMemoryQuotaDialog", function (event, services) {
        return mnPoolDefault.get().then(function (poolsDefault) {
          var firstTimeAddedServices = mnMemoryQuotaService.getFirstTimeAddedServices(["index", "fts"], services, poolsDefault.nodes);
          if (firstTimeAddedServices.count) {
            $uibModal.open({
              windowTopClass: "without-titlebar-close",
              templateUrl: 'app/mn_admin/mn_servers/memory_quota_dialog/memory_quota_dialog.html',
              controller: 'mnServersMemoryQuotaDialogController as serversMemoryQuotaDialogCtl',
              resolve: {
                memoryQuotaConfig: function (mnMemoryQuotaService) {
                  return mnMemoryQuotaService.memoryQuotaConfig(services)
                },
                indexSettings: function (mnSettingsClusterService) {
                  return mnSettingsClusterService.getIndexSettings();
                },
                firstTimeAddedServices: function() {
                  return firstTimeAddedServices;
                }
              }
            });
          }
        });
      });
    }
  }
})();
