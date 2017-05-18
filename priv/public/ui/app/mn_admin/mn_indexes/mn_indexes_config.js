(function () {
  "use strict";

  angular.module('mnIndexes', [
    'mnViews',
    'mnGsi',
    'mnPluggableUiRegistry',
    'mnElementCrane'
  ]).config(mnIndexesConfig);

  function mnIndexesConfig($stateProvider, mnHelperProvider) {
    $stateProvider
      .state('app.admin.indexes', {
        abstract: true,
        views: {
          "main@app.admin": {
            controller: "mnIndexesController as indexesCtl",
            templateUrl: "app/mn_admin/mn_indexes/mn_indexes.html"
          }
        },
        data: {
          title: "Indexes"
        }
      })
      .state('app.admin.indexes.gsi', {
        url: "/index?openedIndex",
        params: {
          openedIndex: {
            array: true,
            dynamic: true
          }
        },
        data: {
          permissions: "cluster.indexes.read"
        },
        controller: "mnGsiController as gsiCtl",
        templateUrl: "app/mn_admin/mn_indexes/mn_gsi/mn_gsi.html"
      });

    addViewsStates("app.admin.indexes");
    addViewsStates("app.admin.buckets");

    function addViewsStates(parent) {
      var viewsState = {
        abstract: true,
        url: '/views?bucket',
        params: {
          bucket: {
            value: null
          }
        },
        data: {
          permissions: "cluster.bucket['.'].settings.read && cluster.bucket['.'].views.read"
        },
        views: {}
      };

      if (parent !== "app.admin.indexes") {
        viewsState.data.title = "Views";
        viewsState.data.child = parent;
      }

      viewsState.views[parent !== "app.admin.indexes" ? "main@app.admin" : ""] = {
        templateUrl: 'app/mn_admin/mn_indexes/mn_views/mn_views.html',
        controller: 'mnViewsController as viewsCtl'
      };

      $stateProvider
        .state(parent + '.views', viewsState)
        .state(parent + '.views.list', {
          url: "?type",
          params: {
            type: {
              value: 'development'
            }
          },
          controller: 'mnViewsListController as viewsListCtl',
          templateUrl: 'app/mn_admin/mn_indexes/mn_views/list/mn_views_list.html'
        })
        .state(parent + '.views.list.editing', {
          abstract: true,
          url: '/:documentId?viewId&{isSpatial:bool}&sampleDocumentId',
          views: {
            "main@app.admin": {
              controller: 'mnViewsEditingController as viewsEditingCtl',
              templateUrl: 'app/mn_admin/mn_indexes/mn_views/editing/mn_views_editing.html'
            }
          },
          data: {
            child: parent + ".views.list",
            title: "Views Editing"
          }
        })
        .state(parent + '.views.list.editing.result', {
          url: '?subset&{pageNumber:int}&viewsParams',
          params: {
            full_set: {
              value: null
            },
            pageNumber: {
              value: 0
            },
            activate: {
              value: null,
              dynamic: true
            }
          },
          controller: 'mnViewsEditingResultController as viewsEditingResultCtl',
          templateUrl: 'app/mn_admin/mn_indexes/mn_views/editing/mn_views_editing_result.html'
        });

    }
  }

})();
