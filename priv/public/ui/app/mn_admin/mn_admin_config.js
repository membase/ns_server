(function () {
  "use strict";

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
    'mnGroups',
    'mnDocuments',
    'mnSettings',
    'mnXDCR',
    'mnSecurity',
    'mnPoll',
    'mnLaunchpad',
    'mnFilters',
    'mnPluggableUiRegistry',
    'mnAboutDialog',
    'mnInternalSettings',
    'mnLostConnection',
    'ui.router',
    'ui.bootstrap',
    'mnPoorMansAlerts'
  ]).config(mnAdminConfig);

  function mnAdminConfig($stateProvider, $urlRouterProvider, $urlMatcherFactoryProvider, mnHelperProvider) {

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
        resolve: {
          poolDefault: function (mnPoolDefault) {
            return mnPoolDefault.getFresh();
          }
        },
        views: {
          "": {
            controller: 'mnAdminController as adminCtl',
            templateUrl: 'app/mn_admin/mn_admin.html'
          },
          "lostConnection@app.admin": {
            templateUrl: 'app/mn_admin/mn_lost_connection/mn_lost_connection.html',
            controller: 'mnLostConnectionController as lostConnCtl'
          }
        }
      })
      .state('app.admin.overview', {
        url: '/overview',
        controller: 'mnOverviewController as overviewCtl',
        templateUrl: 'app/mn_admin/mn_overview/mn_overview.html'
      })
      .state('app.admin.documents', {
        abstract: true,
        templateUrl: 'app/mn_admin/mn_documents/mn_documents.html',
        data: {
          required: {
            admin: true
          }
        },
        controller: "mnDocumentsController as documentsCtl",
        url: "/documents?documentsBucket"
      })
      .state('app.admin.documents.control', {
        abstract: true,
        controller: 'mnDocumentsControlController as documentsControlCtl',
        templateUrl: 'app/mn_admin/mn_documents/list/mn_documents_control.html'
      })
      .state('app.admin.documents.control.list', {
        url: "?{pageLimit:int}&{pageNumber:int}&documentsFilter",
        params: {
          pageLimit: {
            value: 5
          },
          pageNumber: {
            value: 0
          },
          documentsFilter: null
        },
        controller: 'mnDocumentsListController as documentsListCtl',
        templateUrl: 'app/mn_admin/mn_documents/list/mn_documents_list.html'
      })
      .state('app.admin.documents.editing', {
        url: '/:documentId',
        controller: 'mnDocumentsEditingController as documentsEditingCtl',
        templateUrl: 'app/mn_admin/mn_documents/editing/mn_documents_editing.html'
      })
      .state('app.admin.analytics', {
        abstract: true,
        url: '/analytics?statsHostname&analyticsBucket&specificStat',
        controller: 'mnAnalyticsController as analyticsCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics.html',
        params: {
          analyticsBucket: {
            value: null
          }
        },
        resolve: {
          setDefaultBucketName: mnHelperProvider.setDefaultBucketName("analyticsBucket", 'app.admin.analytics.list.graph')
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
        controller: 'mnAnalyticsListController as analyticsListCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list.html'
      })
      .state('app.admin.analytics.list.graph', {
        url: '/:graph?zoom',
        params: {
          graph: {
            value: 'ops'
          },
          zoom: {
            value: 'minute'
          }
        },
        controller: 'mnAnalyticsListGraphController as analyticsListGraphCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list_graph.html'
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
            controller: 'mnBucketsController as bucketsCtl',
            templateUrl: 'app/mn_admin/mn_buckets/mn_buckets.html'
          },
          "details@app.admin.buckets": {
            templateUrl: 'app/mn_admin/mn_buckets/details/mn_buckets_details.html',
            controller: 'mnBucketsDetailsController as bucketsDetailsCtl'
          }
        }
      })
      .state('app.admin.servers', {
        abstract: true,
        url: '/servers',
        controller: 'mnServersController as serversCtl',
        templateUrl: 'app/mn_admin/mn_servers/mn_servers.html'
      })
      .state('app.admin.servers.list', {
        url: '/:list?openedServers',
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
            controller: 'mnServersListController as serversListCtl',
            templateUrl: 'app/mn_admin/mn_servers/list/mn_servers_list.html'
          },
          "details@app.admin.servers.list": {
            templateUrl: 'app/mn_admin/mn_servers/details/mn_servers_list_item_details.html',
            controller: 'mnServersListItemDetailsController as serversListItemDetailsCtl'
          }
        }
      })
      .state('app.admin.groups', {
        url: '/groups',
        templateUrl: 'app/mn_admin/mn_groups/mn_groups.html',
        controller: 'mnGroupsController as groupsCtl',
        data: {
          required: {
            admin: true,
            enterprise: true
          }
        }
      })
      .state('app.admin.replications', {
        url: '/replications',
        templateUrl: 'app/mn_admin/mn_xdcr/mn_xdcr.html',
        controller: 'mnXDCRController as xdcrCtl'
      })
      .state('app.admin.logs', {
        url: '/logs',
        abstract: true,
        templateUrl: 'app/mn_admin/mn_logs/mn_logs.html',
        controller: 'mnLogsController as logsCtl'
      })
      .state('app.admin.logs.list', {
        url: '',
        controller: 'mnLogsListController as logsListCtl',
        templateUrl: 'app/mn_admin/mn_logs/list/mn_logs_list.html'
      })
      .state('app.admin.logs.collectInfo', {
        url: '/collectInfo',
        abstract: true,
        controller: 'mnLogsCollectInfoController as logsCollectInfoCtl',
        templateUrl: 'app/mn_admin/mn_logs/collect_info/mn_logs_collect_info.html',
        data: {
          required: {
            admin: true
          }
        }
      })
      .state('app.admin.logs.collectInfo.result', {
        url: '/result',
        templateUrl: 'app/mn_admin/mn_logs/collect_info/mn_logs_collect_info_result.html'
      })
      .state('app.admin.logs.collectInfo.form', {
        url: '/form',
        templateUrl: 'app/mn_admin/mn_logs/collect_info/mn_logs_collect_info_form.html'
      });
  }
})();
