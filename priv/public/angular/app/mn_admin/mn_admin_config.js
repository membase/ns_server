angular.module('mnAdmin').config(function ($stateProvider, $urlRouterProvider) {

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
    .state('app.admin.views', {
      url: '/views/:type?viewsBucket',
      params: {
        type: {
          value: 'development'
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
      url: '/buckets',
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
    .state('app.admin.servers', {
      url: '/servers/:list',
      params: {
        list: {
          value: 'active'
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
        defaultCertificate: function (mnSettingsClusterService) {
          return mnSettingsClusterService.getDefaultCertificate();
        },
        nodes: function (mnServersService) {
          return mnServersService.getNodes();
        },
        poolDefault: function (mnPoolDefault) {
          return mnPoolDefault.getFresh();
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
    });
});