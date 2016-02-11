(function () {
  "use strict";

  angular
    .module("mnViewsListService", [
      'mnTasksDetails',
      'mnBucketsService',
    ])
    .factory("mnViewsListService", mnViewsListFactory);

  function mnViewsListFactory($http, $q, $window, mnTasksDetails, mnBucketsService) {
    var mnViewsListService = {
      createDdoc: createDdoc,
      getDdocUrl: getDdocUrl,
      getDdoc: getDdoc,
      deleteDdoc: deleteDdoc,
      cutOffDesignPrefix: cutOffDesignPrefix,
      getKvNodeLink: getKvNodeLink,
      getDdocs: getDdocs,
      getViewsListState: getViewsListState,
      getDdocsByType: getDdocsByType,
      getTasksOfCurrentBucket: getTasksOfCurrentBucket,
      isDevModeDoc: isDevModeDoc,
      prepareBucketsDropdownData: prepareBucketsDropdownData
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
      return $http({
        method: 'PUT',
        url: url,
        data: json,
        mnHttp: {
          isNotForm: true
        }
      }).then(handleCouchRequest);
    }
    function getDdocUrl(bucket, name) {
      var encodedName = encodeURIComponent(cutOffDesignPrefix(name));
      if (name.indexOf("_design/dev_") > -1) {
        encodedName = "_design/dev_" + encodedName;
      } else if (name.indexOf("_design/") > -1) {
        encodedName = "_design/" + encodedName;
      }
      return '/couchBase/' + encodeURIComponent(bucket) + '/' + encodedName;
    }
    function getDdoc(url) {
      return $http({
        method: 'GET',
        url: url
      }).then(handleCouchRequest);
    }
    function deleteDdoc(url) {
      return $http({
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
    function getEmptyViewsState() {
      var rv = {}
      rv.development = [];
      rv.production = [];
      return $q.when(rv);
    }
    function getKvNodeLink(nodes) {
      var kvNode = _.find(nodes, function (node) {
        return node.status === "healthy" && _.indexOf(node.services, "kv") > -1;
      });

      var hostnameAndPort = kvNode.hostname.split(':');
      var protocol = $window.location.protocol;
      var kvNodeLink = protocol + "//" + (protocol === "https:" ? hostnameAndPort[0] + ":" + kvNode.ports.httpsMgmt : kvNode.hostname);

      return kvNodeLink;
    }
    function getDdocs(viewsBucket, mnHttpParams) {
      return $http({
        method: "GET",
        url: '/pools/default/buckets/' + encodeURIComponent(viewsBucket) + '/ddocs',
        mnHttp: mnHttpParams
      });
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
      }, function (resp) {
        switch (resp.status) {
          case 400: return getEmptyViewsState().then(function (emptyState) {
            emptyState.ddocsAreInFactMissing = resp.data.error === 'no_ddocs_service';
            return emptyState;
          });
          case 0:
          case -1: return $q.reject(resp);
          default: return getEmptyViewsState();
        }
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
      if (params.viewsBucket) {
        return getDdocsByType(params.viewsBucket);
      } else {
        return getEmptyViewsState();
      }
    }
  }
})();
