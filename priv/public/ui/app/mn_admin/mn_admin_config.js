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
    'mnInternalSettings',
    'mnLostConnection',
    'ui.router',
    'ui.bootstrap',
    'mnPoorMansAlerts',
    'mnPermissions',
    'mnMemoryQuotaService',
    'mnElementCrane',
    'ngAnimate',
    'mnDragAndDrop',
    'mnResetPasswordDialog',
    'mnResetPasswordDialogService'
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
          },
          pools: function (mnPools) {
            return mnPools.get();
          },
          permissions: function (mnPermissions) {
            return mnPermissions.check();
          },
          whoami: function (mnAuthService) {
            return mnAuthService.whoami();
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
        views: {
          "main@app.admin": {
            controller: 'mnOverviewController as overviewCtl',
            templateUrl: 'app/mn_admin/mn_overview/mn_overview.html'
          }
        },
        data: {
          title: "Dashboard"
        }
      })
      .state('app.admin.buckets', {
        url: '/buckets?openedBucket',
        params: {
          openedBucket: {
            array: true,
            dynamic: true
          }
        },
        views: {
          "main@app.admin": {
            controller: 'mnBucketsController as bucketsCtl',
            templateUrl: 'app/mn_admin/mn_buckets/mn_buckets.html'
          },
          "details@app.admin.buckets": {
            templateUrl: 'app/mn_admin/mn_buckets/details/mn_buckets_details.html',
            controller: 'mnBucketsDetailsController as bucketsDetailsCtl'
          },
          "item@app.admin.buckets": {
            templateUrl: 'app/mn_admin/mn_buckets/list/item/mn_buckets_list_item.html',
            controller: 'mnBucketsListItemController as bucketsItemCtl'
          }
        },
        data: {
          title: "Buckets",
          permissions: "cluster.bucket['.'].settings.read"
        }
      })
      .state('app.admin.servers', {
        abstract: true,
        url: '/servers',
        views: {
          "main@app.admin": {
            controller: 'mnServersController as serversCtl',
            templateUrl: 'app/mn_admin/mn_servers/mn_servers.html'
          }
        },
        data: {
          title: "Servers"
        }
      })
      .state('app.admin.servers.list', {
        url: '/list?openedServers',
        params: {
          openedServers: {
            array: true,
            dynamic: true
          }
        },
        views: {
          "" : {
            templateUrl: 'app/mn_admin/mn_servers/list/mn_servers_list.html'
          },
          "details@app.admin.servers.list": {
            templateUrl: 'app/mn_admin/mn_servers/details/mn_servers_list_item_details.html',
            controller: 'mnServersListItemDetailsController as serversListItemDetailsCtl'
          },
          "item@app.admin.servers.list": {
            templateUrl: 'app/mn_admin/mn_servers/list/item/mn_servers_list_item.html',
            controller: 'mnServersListItemController as serversItemCtl'
          }
        }
      })
      .state('app.admin.replications', {
        url: '/replications',
        views: {
          "main@app.admin": {
            templateUrl: 'app/mn_admin/mn_xdcr/mn_xdcr.html',
            controller: 'mnXDCRController as xdcrCtl'
          }
        },
        data: {
          permissions: "cluster.tasks.read",
          title: "XDCR Replications"
        }
      })
      .state('app.admin.logs', {
        url: '/logs',
        abstract: true,
        views: {
          "main@app.admin": {
            templateUrl: 'app/mn_admin/mn_logs/mn_logs.html',
            controller: 'mnLogsController as logsCtl'
          }
        },
        data: {
          title: "Logs",
          permissions: "cluster.logs.read"
        }
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
          permissions: "cluster.admin.logs.read",
          title: "Collect Information"
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

  addAnalyticsStates("app.admin.servers.list");
  addGroupsStates("app.admin.servers.list");

  addAnalyticsStates("app.admin.buckets");
  addDocumentsStates("app.admin.buckets");


  function addGroupsStates(parent) {
    $stateProvider.state(parent + '.groups', {
      url: '/groups',
      views: {
        "main@app.admin": {
          templateUrl: 'app/mn_admin/mn_groups/mn_groups.html',
          controller: 'mnGroupsController as groupsCtl'
        }
      },
      data: {
        enterprise: true,
        permissions: "cluster.server_groups.read",
        title: "Server Groups",
        child: parent
      }
    });
  }

  function addDocumentsStates(parent) {
    $stateProvider
      .state(parent + '.documents', {
        abstract: true,
        views: {
          "main@app.admin": {
            templateUrl: 'app/mn_admin/mn_documents/mn_documents.html',
            controller: "mnDocumentsController as documentsCtl"
          }
        },
        url: "/documents?bucket",
        data: {
          title: "Documents",
          child: parent,
          permissions: "cluster.bucket['.'].settings.read && cluster.bucket['.'].data.read"
        }
      })
      .state(parent + '.documents.control', {
        abstract: true,
        controller: 'mnDocumentsControlController as documentsControlCtl',
        templateUrl: 'app/mn_admin/mn_documents/list/mn_documents_control.html'
      })
      .state(parent + '.documents.control.list', {
        url: "?{pageLimit:int}&{pageNumber:int}&documentsFilter",
        params: {
          pageLimit: {
            value: 10
          },
          pageNumber: {
            value: 0
          },
          documentsFilter: null
        },
        controller: 'mnDocumentsListController as documentsListCtl',
        templateUrl: 'app/mn_admin/mn_documents/list/mn_documents_list.html'
      })
      .state(parent + '.documents.editing', {
        url: '/:documentId',
        controller: 'mnDocumentsEditingController as documentsEditingCtl',
        templateUrl: 'app/mn_admin/mn_documents/editing/mn_documents_editing.html',
        data: {
          child: parent + ".documents.control.list",
          title: "Documents Editing"
        }
      });
  }

  function addAnalyticsStates(parent) {
    $stateProvider
      .state(parent + '.analytics', {
        abstract: true,
        url: '/analytics?statsHostname&bucket&specificStat',
        views: {
          "main@app.admin": {
            controller: 'mnAnalyticsController as analyticsCtl',
            templateUrl: 'app/mn_admin/mn_analytics/mn_analytics.html'
          }
        },
        params: {
          specificStat: {
            value: null
          },
          bucket: {
            value: null
          }
        },
        data: {
          permissions: "cluster.bucket['.'].settings.read && " +
            "cluster.bucket['.'].stats.read && cluster.stats.read"
        }
      })
      .state(parent + '.analytics.list', {
        url: '?openedStatsBlock&openedSpecificStatsBlock',
        params: {
          openedStatsBlock: {
            array: true,
            dynamic: true
          },
          openedSpecificStatsBlock: {
            array: true,
            dynamic: true
          },
          transZoom: {
            dynamic: true
          },
          transGraph: {
            dynamic: true
          }
        },
        data: {
          title: "Statistics",
          child: parent
        },
        controller: 'mnAnalyticsListController as analyticsListCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list.html',
        redirectTo: function (trans) {
          var mnAnalyticsService = trans.injector().get("mnAnalyticsService");
          var params = _.clone(trans.params(), true);
          params.zoom = params.transZoom || "minute";
          params.graph = params.transGraph;
          return mnAnalyticsService.getStats({$stateParams: params}).then(function (state) {
            function checkLackOfParam(paramName) {
              return !params[paramName] || !params[paramName].length || !_.intersection(params[paramName], _.pluck(state.statsDirectoryBlocks, 'blockName')).length;
            }
            if (!state.status) {
              if (params.specificStat) {
                if (checkLackOfParam("openedSpecificStatsBlock")) {
                  params.openedSpecificStatsBlock = [state.statsDirectoryBlocks[0].blockName];
                }
              } else {
                if (checkLackOfParam("openedStatsBlock")) {
                  params.openedStatsBlock = [
                    state.statsDirectoryBlocks[0].blockName,
                    state.statsDirectoryBlocks[1].blockName
                  ];
                }
              }
              var selectedStat = state.statsByName && state.statsByName[params.graph];
              if (!params.graph && (!selectedStat || !selectedStat.config.data.length)) {
                var findBy = function (info) {
                  return info.config.data.length;
                };
                if (params.specificStat) {
                  var directoryForSearch = state.statsDirectoryBlocks[0];
                } else {
                  var directoryForSearch = state.statsDirectoryBlocks[1];
                }
                selectedStat = _.detect(directoryForSearch.stats, findBy) ||
                  _.detect(state.statsByName, findBy);
                if (selectedStat) {
                  params.graph = selectedStat.name;
                }
              }
            }
            return {state: parent + ".analytics.list" + (params.specificStat ? ".specificGraph" : ".graph"), params: params};
          });
        }
      })
      .state(parent + '.analytics.list.specificGraph', {
        url: '/specific/:graph?zoom',
        params: {
          graph: {
            value: null
          },
          zoom: {
            value: null
          }
        },
        data: {
          title: "Specific",
          child: parent + ".analytics.list",
          childParams: {
            specificStat: null
          }
        },
        controller: 'mnAnalyticsListGraphController as analyticsListGraphCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list_graph.html'
      })
      .state(parent + '.analytics.list.graph', {
        url: '/:graph?zoom',
        params: {
          graph: {
            value: null
          },
          zoom: {
            value: null
          }
        },
        controller: 'mnAnalyticsListGraphController as analyticsListGraphCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list_graph.html'
      });
  }
  }
})();
