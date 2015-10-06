(function () {
  "use strict";

  angular
    .module("mnViewsListService", [
      'mnHttp',
      'mnTasksDetails',
      'mnBucketsService',
      'mnCompaction'
    ])
    .factory("mnViewsListService", mnViewsListFactory);

  function mnViewsListFactory(mnHttp, $q, $window, mnTasksDetails, mnBucketsService, mnCompaction, mnPoolDefault) {
    var mnViewsListService = {
      createDdoc: createDdoc,
      getDdocUrl: getDdocUrl,
      getDdoc: getDdoc,
      deleteDdoc: deleteDdoc,
      cutOffDesignPrefix: cutOffDesignPrefix,
      getViewsState: getViewsState,
      getDdocs: getDdocs,
      getViewsListState: getViewsListState,
      getDdocsByType: getDdocsByType,
      getTasksOfCurrentBucket: getTasksOfCurrentBucket,
      isDevModeDoc: isDevModeDoc
    };

    return mnViewsListService;

    function handleCouchRequest(resp) {
      var data = {
        json : resp.data,
        meta : JSON.parse(resp.headers("X-Couchbase-Meta"))
      };
      return data;
    }
    function createDdoc(url, json) {
      return mnHttp({
        method: 'PUT',
        url: url,
        data: json,
        mnHttp: {
          isNotForm: true
        }
      }).then(handleCouchRequest);
    }
    function getDdocUrl(bucket, name) {
      return '/couchBase/' + encodeURIComponent(bucket) + '/' + name;
    }
    function getDdoc(url) {
      return mnHttp({
        method: 'GET',
        url: url
      }).then(handleCouchRequest);
    }
    function deleteDdoc(url) {
      return mnHttp({
        method: 'DELETE',
        url: url
      });
    }
    function cutOffDesignPrefix(id) {
      return id.replace(/^_design\/(dev_|)/, "");
    }
    function prepareBucketsDropdownData(params, fromCache) {
      return mnBucketsService.getBucketsByType(fromCache).then(function (buckets) {
        var rv = {};
        rv.bucketsNames = buckets.byType.membase.names;
        rv.bucketsNames.selected = params.viewsBucket || buckets.byType.membase.defaultName
        return rv;
      });
    }
    function getEmptyViewsState(params) {
      return prepareBucketsDropdownData(params).then(function (rv) {
        rv.development = [];
        rv.production = [];
        return rv;
      });
    }
    function getViewsState(params) {
      return mnPoolDefault.get().then(function (poolDefault) {
        if (!poolDefault.isKvNode) {
          var kvNode = _.find(poolDefault.nodes, function (node) {
            return node.status === "healthy" && _.indexOf(node.services, "kv") > -1;
          });

          var hostnameAndPort = kvNode.hostname.split(':');
          var protocol = $window.location.protocol;
          var kvNodeLink = protocol + "//" + (protocol === "https:" ? hostnameAndPort[0] + ":" + kvNode.ports.httpsMgmt : kvNode.hostname);

          return {
            kvNodeLink: kvNodeLink
          };
        } else {
          return prepareBucketsDropdownData(params, true);
        }
      });
    }
    function getDdocs(viewsBucket) {
      return mnHttp.get('/pools/default/buckets/' + encodeURIComponent(viewsBucket) + '/ddocs');
    }
    function isDevModeDoc(id) {
      var devPrefix = "_design/dev_";
      return id.substring(0, devPrefix.length) == devPrefix;
    }

    function getDdocsByType(viewsBucket) {
      return getDdocs(viewsBucket).then(function (resp) {
        var ddocs = resp.data;
        ddocs.development = _.filter(ddocs.rows, function (row) {
          return isDevModeDoc(row.doc.meta.id);
        });
        ddocs.production = _.reject(ddocs.rows, function (row) {
          return isDevModeDoc(row.doc.meta.id);
        });
        return ddocs;
      });
    }

    function getTasksOfCurrentBucket(params) {
      return mnTasksDetails.get().then(function (tasks) {
        var rv = {};
        var importance = {
          view_compaction: 2,
          indexer: 1
        };

        _.each(tasks.tasks, function (taskInfo) {
          if ((taskInfo.type !== 'indexer' && taskInfo.type !== 'view_compaction') || taskInfo.bucket !== params.viewsBucket) {
            return;
          }
          var ddoc = taskInfo.designDocument;
          (rv[ddoc] || (rv[ddoc] = [])).push(taskInfo);
        });
        _.each(rv, function (ddocTasks, key) {
          ddocTasks.sort(function (taskA, taskB) {
            return importance[taskA.type] - importance[taskB.type];
          });
        });

        return rv;
      });
    }

    function getViewsListState(params) {
      return getDdocsByType(params.viewsBucket).then(function (ddocs) {
        ddocs.type = params.type;
        ddocs.isDevelopmentViews = params.type === 'development';
        return getTasksOfCurrentBucket(params).then(function (ddocTasks) {
          _.each(ddocs.rows, function (row) {
            row.isDevModeDoc = isDevModeDoc(row.doc.meta.id);
            row.task = (ddocTasks[row.doc.meta.id] || [])[0];
            row.containsViews = !_.isEmpty(row.doc.json.views);
            row.containsSpatials = !_.isEmpty(row.doc.json.spatial);
            row.isEmpty = !row.containsViews && !row.containsSpatials;
            row.disableCompact = row.isEmpty || !!(row.task && row.task.type === 'view_compaction') || !!mnCompaction.getStartedCompactions()[row.controllers.compact];
          });
          return ddocs;
        });
      }, function (resp) {
        switch (resp.status) {
          case 404: return getEmptyViewsState(params);
          case 400: return getEmptyViewsState(params).then(function (emptyState) {
            emptyState.ddocsAreInFactMissing = resp.data.error === 'no_ddocs_service';
            return emptyState;
          });
          case 0: return $q.reject();
        }
      });
    }
  }
})();
