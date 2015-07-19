angular.module('mnAdmin', [
  'mnAlertsService',
  'mnTasksDetails',
  'mnAuthService',
  'mnHelper',
  'mnPromiseHelper',
  'mnBuckets',
  'mnAnalytics',
  'mnLogs',
  'mnOverview',
  'mnIndexes',
  'mnServers',
  'mnSettingsNotifications',
  'mnSettingsCluster',
  'mnSettingsAutoFailover',
  'mnSettingsAutoCompaction',
  'mnSettingsAudit',
  'mnSettingsCluster',
  'mnSettingsAlerts',
  'mnViews',
  'mnXDCR',
  'mnPoll'
]).config(function ($stateProvider, $urlRouterProvider, $urlMatcherFactoryProvider) {

  function valToString(val) {
    return val != null ? val.toString() : val;
  }
  $urlMatcherFactoryProvider.type("string", {
    encode: valToString,
    decode: valToString,
    is: function (val) {
      return (/[^/]*/).test(val);
    }
  });

  $stateProvider
    .state('app.admin', {
      abstract: true,
      templateUrl: 'mn_admin/mn_admin.html',
      controller: 'mnAdminController',
      resolve: {
        tasks: function (mnTasksDetails) {
          return mnTasksDetails.getFresh();
        },
        updates: function (mnSettingsNotificationsService) {
          return mnSettingsNotificationsService.maybeCheckUpdates();
        },
        launchpadSource: function (updates, mnSettingsNotificationsService) {
          return updates.sendStats && mnSettingsNotificationsService.buildPhoneHomeThingy();
        }
      }
    })
    .state('app.admin.overview', {
      url: '/overview',
      controller: 'mnOverviewController',
      templateUrl: 'mn_admin/mn_overview/mn_overview.html',
      resolve: {
        nodes: function (mnServersService) {
          return mnServersService.getNodes();
        },
        buckets: function (mnBucketsService) {
          return mnBucketsService.getBucketsByType();
        }
      }
    })
    .state('app.admin.analytics', {
      abstract: true,
      url: '/analytics?statsHostname&analyticsBucket&zoom&specificStat',
      params: {
        zoom: {
          value: 'minute'
        },
        analyticsBucket: {
          value: function (mnBucketsService) {
            return mnBucketsService.getDefaultBucket();
          }
        }
      },
      controller: 'mnAnalyticsController',
      templateUrl: 'mn_admin/mn_analytics/mn_analytics.html',
      resolve: {
        analyticsStats: function (mnAnalyticsService, $stateParams) {
          return mnAnalyticsService.getStats({$stateParams: $stateParams});
        }
      }
    })
    .state('app.admin.analytics.list', {
      abstract: true,
      url: '?openedStatsBlock',
      params: {
        openedStatsBlock: {
          array: true
        }
      },
      controller: 'mnAnalyticsListController',
      templateUrl: 'mn_admin/mn_analytics/mn_analytics_list.html'
    })
    .state('app.admin.analytics.list.graph', {
      url: '/:graph',
      params: {
        graph: {
          value: 'ops'
        }
      },
      controller: 'mnAnalyticsListGraphController',
      templateUrl: 'mn_admin/mn_analytics/mn_analytics_list_graph.html'
    })
    .state('app.admin.views', {
      url: '/views/:type?viewsBucket',
      params: {
        type: {
          value: 'development'
        },
        viewsBucket: {
          value: function (mnBucketsService) {
            return mnBucketsService.getDefaultBucket();
          }
        }
      },
      templateUrl: 'mn_admin/mn_views/mn_views.html',
      controller: 'mnViewsController',
      resolve: {
        views: function (mnViewsService, $stateParams) {
          return mnViewsService.getViewsState($stateParams);
        }
      }
    })
    .state('app.admin.buckets', {
      url: '/buckets?openedBucket',
      params: {
        openedBucket: {
          array: true
        }
      },
      views: {
        "": {
          controller: 'mnBucketsController',
          templateUrl: 'mn_admin/mn_buckets/mn_buckets.html',
          resolve: {
            buckets: function (mnBucketsService) {
              return mnBucketsService.getBucketsState();
            }
          }
        },
        "details@app.admin.buckets": {
          templateUrl: 'mn_admin/mn_buckets/details/mn_buckets_details.html',
          controller: 'mnBucketsDetailsController'
        }
      }
    })
    .state('app.admin.indexes', {
      url: "/index?openedIndex",
      params: {
        openedIndex: {
          array: true
        }
      },
      controller: "mnIndexesController",
      templateUrl: "mn_admin/mn_indexes/mn_indexes.html",
      resolve: {
        indexesState: function (mnIndexesService) {
          return mnIndexesService.getIndexesState();
        }
      }
    })
    .state('app.admin.servers', {
      url: '/servers/:list?openedServers',
      params: {
        list: {
          value: 'active'
        },
        openedServers: {
          array: true
        }
      },
      views: {
        "" : {
          controller: 'mnServersController',
          templateUrl: 'mn_admin/mn_servers/mn_servers.html',
          resolve: {
            serversState: function (mnServersService, $stateParams) {
              return mnServersService.getServersState($stateParams.list);
            }
          }
        },
        "details@app.admin.servers": {
          templateUrl: 'mn_admin/mn_servers/details/mn_servers_list_item_details.html',
          controller: 'mnServersListItemDetailsController'
        }
      }
    })
    .state('app.admin.replications', {
      url: '/replications',
      templateUrl: 'mn_admin/mn_xdcr/mn_xdcr.html',
      controller: 'mnXDCRController',
      resolve: {
        xdcr: function (mnXDCRService) {
          return mnXDCRService.getReplicationState();
        }
      }
    })
    .state('app.admin.logs', {
      url: '/logs',
      abstract: true,
      templateUrl: 'mn_admin/mn_logs/mn_logs.html'
    })
    .state('app.admin.logs.list', {
      url: '',
      controller: 'mnLogsListController',
      templateUrl: 'mn_admin/mn_logs/list/mn_logs_list.html',
      resolve: {
        logs: function (mnLogsService) {
          return mnLogsService.getLogs();
        }
      }
    })
    .state('app.admin.logs.collectInfo', {
      url: '/collectInfo',
      abstract: true,
      controller: 'mnLogsCollectInfoController',
      templateUrl: 'mn_admin/mn_logs/collect_info/mn_logs_collect_info.html',
      resolve: {
        state: function (mnLogsCollectInfoService) {
          return mnLogsCollectInfoService.getState();
        }
      }
    })
    .state('app.admin.logs.collectInfo.result', {
      url: '/result',
      templateUrl: 'mn_admin/mn_logs/collect_info/mn_logs_collect_info_result.html'
    })
    .state('app.admin.logs.collectInfo.form', {
      url: '/form',
      templateUrl: 'mn_admin/mn_logs/collect_info/mn_logs_collect_info_form.html'
    })
    .state('app.admin.settings', {
      url: '/settings',
      abstract: true,
      templateUrl: 'mn_admin/mn_settings/mn_settings.html'
    })
    .state('app.admin.settings.cluster', {
      url: '/cluster',
      controller: 'mnSettingsClusterController',
      templateUrl: 'mn_admin/mn_settings/cluster/mn_settings_cluster.html',
      resolve: {
        clusterState: function (mnSettingsClusterService) {
          return mnSettingsClusterService.getClusterState();
        }
      }
    })
    .state('app.admin.settings.notifications', {
      url: '/notifications',
      controller: 'mnSettingsNotificationsController',
      templateUrl: 'mn_admin/mn_settings/notifications/mn_settings_notifications.html'
    })
    .state('app.admin.settings.autoFailover', {
      url: '/autoFailover',
      controller: 'mnSettingsAutoFailoverController',
      templateUrl: 'mn_admin/mn_settings/auto_failover/mn_settings_auto_failover.html',
      resolve: {
        autoFailoverSettings: function (mnSettingsAutoFailoverService) {
          return mnSettingsAutoFailoverService.getAutoFailoverSettings();
        }
      }
    })
    .state('app.admin.settings.alerts', {
      url: '/alerts',
      controller: 'mnSettingsAlertsController',
      templateUrl: 'mn_admin/mn_settings/alerts/mn_settings_alerts.html',
      resolve: {
        alertsSettings: function (mnSettingsAlertsService) {
          return mnSettingsAlertsService.getAlerts();
        }
      }
    })
    .state('app.admin.settings.autoCompaction', {
      url: '/autoCompaction',
      controller: 'mnSettingsAutoCompactionController',
      templateUrl: 'mn_admin/mn_settings/auto_compaction/mn_settings_auto_compaction.html',
      resolve: {
        autoCompactionSettings: function (mnSettingsAutoCompactionService) {
          return mnSettingsAutoCompactionService.getAutoCompaction();
        }
      }
    })
    .state('app.admin.settings.audit', {
      url: '/audit',
      controller: 'mnSettingsAuditController',
      templateUrl: 'mn_admin/mn_settings/audit/mn_settings_audit.html',
      resolve: {
        auditSettings: function (mnSettingsAuditService) {
          return mnSettingsAuditService.getAuditSettings();
        }
      }
    });
});