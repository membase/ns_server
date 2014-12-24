angular.module('mnAdmin').config(function ($stateProvider, $urlRouterProvider) {

  $stateProvider
    .state('app.admin', {
      abstract: true,
      templateUrl: 'mn_admin/mn_admin.html',
      controller: 'mnAdminController',
      resolve: {
        tasks: function (mnTasksDetails) {
          return mnTasksDetails.getFresh();
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
        getVisulaSettings: function (mnSettingsClusterService) {
          return mnSettingsClusterService.getVisulaSettings();
        },
        nodes: function (mnServersService) {
          return mnServersService.getNodes();
        },
        poolDefault: function (mnPoolDefault) {
          return mnPoolDefault.getFresh();
        }
      }
    });
});