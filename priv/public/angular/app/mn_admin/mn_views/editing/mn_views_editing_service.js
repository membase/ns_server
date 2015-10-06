(function () {
  "use strict";

  angular
    .module("mnViewsEditingService", ["mnHttp", "mnViewsListService", "mnDocumentsEditingService", "mnViewsListService", "mnFilters"])
    .factory("mnViewsEditingService", mnViewsEditingFactory);

  function mnViewsEditingFactory(mnHttp, $state, mnViewsListService, mnDocumentsEditingService, $q, removeEmptyValueFilter, $httpParamSerializerJQLike, mnPoolDefault, viewsPerPageLimit) {
    var mnViewsEditingService = {
      getViewsEditingState: getViewsEditingState,
      prepareRandomDocument: prepareRandomDocument,
      getViewResult: getViewResult,
      getFilterParams: getFilterParams,
      getFilterParamsAsString: getFilterParamsAsString,
      buildViewUrl: buildViewUrl,
      getInitialViewsFilterParams: getInitialViewsFilterParams
    };
    return mnViewsEditingService;

    function getInitialViewsFilterParams(isSpatial) {
      return isSpatial ? {
        limit: viewsPerPageLimit,
        stale: "false",
        connection_timeout: 60000,
      } : {
        limit: viewsPerPageLimit,
        stale: "false",
        connection_timeout: 60000,
        inclusive_end: true,
        reduce: ""
      };
    }

    function buildViewUrl(params) {
      var params = _.clone(params);
      if (params.documentId.slice(0, "_design/".length) === "_design/") {
        params.documentId = "_design/" + encodeURIComponent(params.documentId.slice("_design/".length));
      }
      if (params.documentId.slice(0, "_local/".length) === "_local/") {
        params.documentId = "_local/" + encodeURIComponent(params.documentId.slice("_local/".length));
      }
      return encodeURIComponent(params.viewsBucket) + "/" + params.documentId + (params.isSpatial ? "/_spatial/" : "/_view/") + encodeURIComponent(params.viewId);
    }

    function getRandomKey(viewsBucket) {
      return mnHttp({
        method: "GET",
        url: "/pools/default/buckets/" + encodeURIComponent(viewsBucket) + "/localRandomKey"
      });
    }
    function getFilterParamsAsString(params) {
      return "?" + $httpParamSerializerJQLike(removeEmptyValueFilter(getFilterParams(params)));
    }
    function getFilterParams(params) {
      params = params || $state.params;
      var filterParams
      try {
        filterParams = JSON.parse(params.viewsParams) || {};
      } catch(e) {
        filterParams = {};
      }
      filterParams.skip = params.pageNumber * viewsPerPageLimit;
      filterParams.full_set = params.full_set;
      return filterParams;
    }
    function getViewResult(params) {
      return mnHttp({
        method: "GET",
        url: "/couchBase/" + buildViewUrl(params),
        params: removeEmptyValueFilter(getFilterParams(params)),
        timeout: 3600000
      }).then(function (resp) {
        resp.data.rows = _.filter(resp.data.rows, function (r) {
          return ('key' in r);
        });
        return resp.data;
      }, function (view) {
        return mnViewsListService.getTasksOfCurrentBucket(params).then(function (tasks) {
          view.data.from = buildViewUrl(params) + getFilterParamsAsString(params);
          var indexingRunning = _.filter(tasks[params.documentId], function (item) {
            return item.type == "indexer" && item.status == "running" && item.designDocument == params.documentId;
          }).length;
          if ((view.data.error === "timeout" || view.config.timeout.value === "timeout") && indexingRunning) {
            view.data.error === "timeout";
            view.data.reason = "node is still building up the index";
            view.data.showBtn = true;
          }
          return $q.reject(view);
        });
      });
    }

    function prepareDropboxItem(isSpatial, ddoc) {
      return function (value, key) {
        return {viewId: key, documentId: ddoc.doc.meta.id, name: key + (isSpatial ? " [Spatial]" : ""), isSpatial: isSpatial};
      };
    }

    function prepareDdocDropboxItem(ddoc) {
      return ([{name: ddoc.doc.meta.id, isDisabled: true}])
        .concat(_.map(ddoc.doc.json.spatial, prepareDropboxItem(true, ddoc)))
        .concat(_.map(ddoc.doc.json.views, prepareDropboxItem(false, ddoc)));
    }

    function getSampleDocument(params) {
      return mnDocumentsEditingService.getDocument(params).then(function (sampleDocument) {
        return sampleDocument.data;
      }, function (resp) {
        switch(resp.status) {
          case 404: return {
            source: {
              meta: {
                id: resp.data.key
              }
            },
            warnings: {
              documentDoesnotExist: true
            }
          };
        }
      });
    }

    function prepareRandomDocument(params) {
      return params.sampleDocumentId ? getSampleDocument({
        documentId: params.sampleDocumentId,
        documentsBucket: params.viewsBucket
      }) : getRandomKey(params.viewsBucket).then(function (resp) {
        return getSampleDocument({
          documentId: resp.data.key,
          documentsBucket: params.viewsBucket
        });
      }, function (resp) {
        switch(resp.status) {
          case 404: return {
            warnings: {
              thereAreNoDocs: true
            }
          };
        }
      });
    }
    function getEmptyViewState(params) {
      return prepareViewsSelectbox(params).then(function (rv) {
        rv.isEmptyState = true;
        return rv;
      });
    }

    function prepareViewsSelectbox(params) {
      return mnViewsListService.getDdocsByType(params.viewsBucket).then(function (ddocs) {
        var rv = {};
        if (ddocs.rows.length) {
          var viewsNames = [];
          if (ddocs.development.length) {
            viewsNames.push({name: "Development Views", isDisabled: true});
            viewsNames = viewsNames.concat(_.map(ddocs.development, prepareDdocDropboxItem));
          }
          if (ddocs.production.length) {
            viewsNames.push({name: "Production Views", isDisabled: true});
            viewsNames = viewsNames.concat(_.map(ddocs.production, prepareDdocDropboxItem));
          }
          rv.viewsNames = _.flatten(viewsNames);
          rv.viewsNames.selected = _.find(rv.viewsNames, function (item) {
            return item.viewId === params.viewId && item.documentId === params.documentId;
          });
          rv.ddocs = ddocs;
        }
        return rv;
      })
    }

    function getViewsEditingState(params) {
      return mnHttp({
        method: "GET",
        url: "/couchBase/" + buildViewUrl(params)
      }).then(function () {
        return $q.all([
          prepareViewsSelectbox(params),
          mnPoolDefault.get()
        ]).then(function (resp) {
          var rv = resp[0];
          var poolDefault = resp[1];
          rv.capiBase = poolDefault.capiBase;
          rv.isDevelopmentDocument = mnViewsListService.isDevModeDoc(params.documentId)
          if (rv.ddocs.rows.length) {
            rv.currentDocument = _.find(rv.ddocs.rows, function (row) {
              return row.doc.meta.id === params.documentId;
            });
            return prepareRandomDocument(params).then(function (randomDoc) {
              rv.sampleDocument = randomDoc;
              return rv;
            });
          } else {
            return rv;
          }
        });
      }, function (resp) {
        switch (resp.status) {
          case 404: return getEmptyViewState(params);
        }
      });
    }
  }
})();
