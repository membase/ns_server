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
    'mnDragAndDrop'
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
          }
        },
        data: {
          title: "Buckets"
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
        url: '/{list:(?:active|pending)}?openedServers',
        params: {
          list: {
            value: 'active'
          },
          openedServers: {
            array: true,
            dynamic: true
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
      .state('app.admin.replications', {
        url: '/replications',
        views: {
          "main@app.admin": {
            templateUrl: 'app/mn_admin/mn_xdcr/mn_xdcr.html',
            controller: 'mnXDCRController as xdcrCtl'
          }
        },
        data: {
          title: "Replication"
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
          title: "Logs"
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
          child: parent
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
      .state(parent + '.documents.editing', {
        url: '/:documentId',
        controller: 'mnDocumentsEditingController as documentsEditingCtl',
        templateUrl: 'app/mn_admin/mn_documents/editing/mn_documents_editing.html',
        data: {
          child: parent + ".documents",
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
          bucket: {
            value: null
          }
        },
        resolve: {
          setDefaultBucketName: mnHelperProvider.setDefaultBucketName("bucket", parent + '.analytics.list.graph', true)
        },
        data: {
          title: "Statistics",
          child: parent
        }
      })
      .state(parent + '.analytics.list', {
        abstract: true,
        url: '?openedStatsBlock&openedSpecificStatsBlock',
        params: {
          openedStatsBlock: {
            array: true,
            dynamic: true
          },
          openedSpecificStatsBlock: {
            array: true,
            dynamic: true
          }
        },
        controller: 'mnAnalyticsListController as analyticsListCtl',
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list.html'
      })
      .state(parent + '.analytics.list.graph', {
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
        templateUrl: 'app/mn_admin/mn_analytics/mn_analytics_list_graph.html',
        resolve: {
          setDefaultGraph: function (mnAnalyticsService, setDefaultBucketName, $state, $q, $transition$) {
            var params = $transition$.params();
            if (!params.bucket) {
              return;
            }
            return mnAnalyticsService.getStats({$stateParams: params}).then(function (state) {
              if (state.isEmptyState) {
                return;
              }
              var originalParams = _.clone(params);
              function checkLackOfParam(paramName) {
                return !params[paramName] || !params[paramName].length || !_.intersection(params[paramName], _.pluck(state.statsDirectoryBlocks, 'blockName')).length;
              }
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
              if (!selectedStat || !selectedStat.config.data.length) {
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
              if (!_.isEqual(originalParams, params)) {
                $state.go(parent + ".analytics.list.graph", params);
                return $q.reject();
              }
            });
          }
        }
      });
  }
  }
})();
