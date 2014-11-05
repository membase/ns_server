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
      controller: 'mnAdminOverviewController',
      templateUrl: 'mn_admin/overview/mn_admin_overview.html',
      resolve: {
        nodes: function (mnAdminServersService) {
          return mnAdminServersService.getNodes();
        },
        buckets: function (mnAdminBucketsService) {
          return mnAdminBucketsService.getRawDetailedBuckets();
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
          controller: 'mnAdminServersController',
          templateUrl: 'mn_admin/servers/mn_admin_servers.html',
          resolve: {
            serversState: function (mnAdminServersService, $stateParams) {
              return mnAdminServersService.getServersState($stateParams.list);
            }
          }
        },
        "details@app.admin.servers": {
          templateUrl: 'mn_admin/servers/details/mn_admin_servers_list_item_details.html',
          controller: 'mnAdminServersListItemDetailsController'
        }
      }
    })
    .state('app.admin.settings', {
      url: '/settings',
      abstract: true,
      templateUrl: 'mn_admin/settings/mn_admin_settings.html'
    })
    .state('app.admin.settings.cluster', {
      url: '/cluster',
      controller: 'mnAdminSettingsClusterController',
      templateUrl: 'mn_admin/settings/cluster/mn_admin_settings_cluster.html',
      resolve: {
        defaultCertificate: function (mnAdminSettingsClusterService) {
          return mnAdminSettingsClusterService.getDefaultCertificate();
        },
        getVisulaSettings: function (mnAdminSettingsClusterService) {
          return mnAdminSettingsClusterService.getVisulaSettings();
        },
        nodes: function (mnAdminServersService) {
          return mnAdminServersService.getNodes();
        },
        poolDetails: function (mnPoolDetails) {
          return mnPoolDetails.getFresh()
        }
      }
    });
});