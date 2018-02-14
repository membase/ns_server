(function () {
  "use strict";

  angular
    .module('mnAdmin')
    .controller('mnAdminController', mnAdminController);

  function mnAdminController($scope, $rootScope, $state, $uibModal, mnAlertsService, poolDefault, mnSettingsNotificationsService, mnPromiseHelper, pools, mnPoller, mnEtagPoller, mnAuthService, mnTasksDetails, mnPoolDefault, mnSettingsAutoFailoverService, formatProgressMessageFilter, mnPrettyVersionFilter, mnPoorMansAlertsService, mnLostConnectionService, mnPermissions, mnPools, mnMemoryQuotaService, mnResetPasswordDialogService, whoami, mnBucketsStats, mnBucketsService, $q, mnSessionService) {
    var vm = this;
    vm.poolDefault = poolDefault;
    vm.launchpadId = pools.launchID;
    vm.implementationVersion = pools.implementationVersion;
    vm.logout = mnAuthService.logout;
    vm.resetAutoFailOverCount = resetAutoFailOverCount;
    vm.isProgressBarClosed = true;
    vm.toggleProgressBar = toggleProgressBar;
    vm.filterTasks = filterTasks;
    vm.showResetPasswordDialog = showResetPasswordDialog;

    vm.user = whoami;

    vm.$state = $state;

    vm.enableInternalSettings = $state.params.enableInternalSettings;
    vm.runInternalSettingsDialog = runInternalSettingsDialog;
    vm.lostConnState = mnLostConnectionService.getState();

    vm.clientAlerts = mnAlertsService.clientAlerts;
    vm.alerts = mnAlertsService.alerts;
    vm.closeAlert = mnAlertsService.removeItem;

    $rootScope.rbac = mnPermissions.export;
    $rootScope.poolDefault = mnPoolDefault.export;
    $rootScope.pools = mnPools.export;
    $rootScope.buckets = mnBucketsService.export;

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
      var queries = [
        mnSettingsAutoFailoverService.resetAutoFailOverCount({group: "global"})
      ];
      if (mnPoolDefault.export.compat.atLeast50) {
        queries.push(mnSettingsAutoFailoverService.resetAutoReprovisionCount({group: "global"}));
      }
      mnPromiseHelper(vm, $q.all(queries))
        .reloadState()
        .showSpinner('resetQuotaLoading')
        .catchGlobalErrors('Unable to reset Auto-failover quota!')
        .showGlobalSuccess("Auto-failover quota reset successfully!");
    }

    function activate() {
      mnSessionService.init($scope);
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

        if ((previous && previous.uiSessionTimeout) !== resp.uiSessionTimeout) {
          $rootScope.$broadcast("newSessionTimeout", resp.uiSessionTimeout);
        }

        vm.tabName = resp.clusterName;

        if (previous && !_.isEqual(resp.nodes, previous.nodes)) {
          $rootScope.$broadcast("nodesChanged", [resp.nodes, previous.nodes]);
        }

        if (previous && previous.buckets.uri !== resp.buckets.uri) {
          $rootScope.$broadcast("reloadBucketStats");
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
          $rootScope.$broadcast("reloadPermissions");
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

      $scope.$on("reloadPermissions", function () {
        mnPermissions.getFresh();
      });

      $scope.$on("newSessionTimeout", function (e, uiSessionTimeout) {
        mnSessionService.setTimeout(uiSessionTimeout);
        mnSessionService.resetTimeoutAndSyncAcrossTabs();
      });

      $scope.$on("reloadTasksPoller", function (event, params) {
        if (!params || !params.doNotShowSpinner) {
          vm.showTasksSpinner = true;
        }
        if (tasksPoller) {
          tasksPoller.reload(true);
        }
      });

      $scope.$on("reloadPoolDefaultPoller", function () {
        mnPoolDefault.clearCache();
        etagPoller.reload();
      });

      $scope.$on("reloadBucketStats", function () {
        mnBucketsService.clearCache();
        mnBucketsService.getBucketsByType();
      });
      $rootScope.$broadcast("reloadBucketStats");

      $scope.$on("maybeShowMemoryQuotaDialog", function (event, services) {
        return mnPoolDefault.get().then(function (poolsDefault) {
          var servicesToCheck = ["index", "fts"];
          if (poolsDefault.isEnterprise) {
            servicesToCheck = servicesToCheck.concat(["cbas", "eventing"]);
          }
          var firstTimeAddedServices =
              mnMemoryQuotaService
              .getFirstTimeAddedServices(servicesToCheck, services, poolsDefault.nodes);
          if (firstTimeAddedServices.count) {
            $uibModal.open({
              windowTopClass: "without-titlebar-close",
              templateUrl: 'app/mn_admin/mn_servers/memory_quota_dialog/memory_quota_dialog.html',
              controller: 'mnServersMemoryQuotaDialogController as serversMemoryQuotaDialogCtl',
              resolve: {
                memoryQuotaConfig: function (mnMemoryQuotaService) {
                  return mnMemoryQuotaService.memoryQuotaConfig(services, true, false);
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
