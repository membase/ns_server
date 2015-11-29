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
    'mnViews',
    'mnXDCR',
    'mnPoll',
    'mnLaunchpad',
    'mnFilters',
    'mnPluggableUiRegistry',
    'mnAboutDialog'
  ]).config(mnAdminConfig);

  function mnAdminConfig($stateProvider, $urlRouterProvider, $urlMatcherFactoryProvider) {

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
        templateUrl: 'app/mn_admin/mn_admin.html',
        controller: 'mnAdminController as adminCtl',
        resolve: {
          poolDefault: function (mnPoolDefault) {
            return mnPoolDefault.getFresh();
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
        params: {
          pageLimit: {
            value: 5
          },
          pageNumber: {
            value: 0
          },
          documentsFilter: null
        },
        controller: "mnDocumentsController as documentsCtl",
        url: "/documents?documentsBucket&{pageLimit:int}&{pageNumber:int}&documentsFilter"
      })
      .state('app.admin.documents.list', {
        url: "",
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
        url: '/analytics?statsHostname&analyticsBucket&zoom&specificStat',
        params: {
          zoom: {
            value: 'minute'
          }
        },
        controller: 'mnAnalyticsController as analyticsCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics.html'
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
        url: '/:graph',
        params: {
          graph: {
            value: 'ops'
          }
        },
        controller: 'mnAnalyticsListGraphController as analyticsListGraphCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list_graph.html'
      })
      .state('app.admin.views', {
        abstract: true,
        url: '/views?viewsBucket',
        params: {
          type: {
            value: 'development'
          }
        },
        templateUrl: 'app/mn_admin/mn_views/mn_views.html',
        controller: 'mnViewsController as viewsCtl'
      })
      .state('app.admin.views.list', {
        url: "?type",
        controller: 'mnViewsListController as viewsListCtl',
        templateUrl: 'app/mn_admin/mn_views/list/mn_views_list.html'
      })
      .state('app.admin.views.editing', {
        abstract: true,
        url: '/:documentId/:viewId?{isSpatial:bool}&sampleDocumentId',
        controller: 'mnViewsEditingController as viewsEditingCtl',
        templateUrl: 'app/mn_admin/mn_views/editing/mn_views_editing.html',
        data: {
          required: {
            admin: true
          }
        }
      })
      .state('app.admin.views.editing.result', {
        url: '?subset&{pageNumber:int}&viewsParams',
        params: {
          full_set: {
            value: null
          },
          pageNumber: {
            value: 0
          }
        },
        controller: 'mnViewsEditingResultController as viewsEditingResultCtl',
        templateUrl: 'app/mn_admin/mn_views/editing/mn_views_editing_result.html'
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
      .state('app.admin.indexes', {
        url: "/index?openedIndex",
        params: {
          openedIndex: {
            array: true
          }
        },
        controller: "mnIndexesController as indexesCtl",
        templateUrl: "app/mn_admin/mn_indexes/mn_indexes.html"
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
            controller: 'mnServersController as serversCtl',
            templateUrl: 'app/mn_admin/mn_servers/mn_servers.html'
          },
          "details@app.admin.servers": {
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
