angular.module('mnViewsService', [
  'mnHttp',
  'mnTasksDetails',
  'mnBucketsService',
  'mnCompaction',
  'ui.select',
  'ngSanitize'
]).service('mnViewsService',
  function (mnHttp, $q, mnTasksDetails, mnBucketsService, mnCompaction) {
    var mnViewsService = {};
    mnViewsService.createDdoc = function (url, ddoc) {
      return mnHttp({
        method: 'PUT',
        url: url,
        data: ddoc
      });
    };

    mnViewsService.getDdocUrl = function (bucket, name) {
      return '/couchBase/' + bucket + '/' + name;
    };

    mnViewsService.getDdoc = function (url) {
      return mnHttp({
        method: 'GET',
        url: url
      }).then(function (resp) {
        return resp.data;
      });
    };
    mnViewsService.deleteDdoc = function (url) {
      return mnHttp({
        method: 'DELETE',
        url: url
      });
    };

    mnViewsService.cutOffDesignPrefix = function (id) {
      return id.replace(/^_design\/(dev_|)/, "");
    };

    function isDevModeDoc(ddoc) {
      var devPrefix = "_design/dev_";
      return ddoc.meta.id.substring(0, devPrefix.length) == devPrefix;
    }

    function getEmptyViewsState() {
      return mnBucketsService.getBucketsByType().then(function (buckets) {
        var rv = {development: [], production: []};
        rv.bucketsNames = buckets ? buckets.byType.membase.names : [];
        return rv;
      });
    }

    mnViewsService.getViewsState = function (params) {
      return mnHttp.get('/pools/default/buckets/' + encodeURIComponent(params.viewsBucket) + '/ddocs').then(function (resp) {
        var ddocs = resp.data;
        return $q.all([
          mnTasksDetails.get(),
          mnBucketsService.getBucketsByType()
        ]).then(function (resp) {
          var tasks = resp[0];
          var buckets = resp[1];
          var ddocTasks = {};
          var importance = {
            view_compaction: 2,
            indexer: 1
          };

          ddocs.bucketsNames = buckets.byType.membase.names;
          ddocs.bucketsNames.selected = params.viewsBucket;

          _.each(tasks.tasks, function (taskInfo) {
            if (taskInfo.type !== 'indexer' && taskInfo.type !== 'view_compaction' && taskInfo.bucket !== params.viewsBucket) {
              return;
            }
            var ddoc = taskInfo.designDocument;
            (ddocTasks[ddoc] || (ddocTasks[ddoc] = [])).push(taskInfo);
          });
          _.each(ddocTasks, function (ddocTasks, key) {
            ddocTasks.sort(function (taskA, taskB) {
              return importance[taskA.type] - importance[taskB.type];
            });
          });
          _.each(ddocs.rows, function (row) {
            row.isDevModeDoc = isDevModeDoc(row.doc);
            row.canEditDoc = row.isDevModeDoc;
            row.task = (ddocTasks[row.doc.meta.id] || [])[0];
            row.containsViews = !_.isEmpty(row.doc.json.views);
            row.containsSpatials = !_.isEmpty(row.doc.json.spatial);
            row.isEmpty = !row.containsViews && !row.containsSpatials;
            row.disableCompact = !!(mnCompaction.getStartedCompactions()[row.controllers.compact] || !!row.task || row.isEmpty);
          });
          ddocs.development = _.filter(ddocs.rows, 'isDevModeDoc');
          ddocs.production = _.reject(ddocs.rows, 'isDevModeDoc');
          ddocs.type = params.type;
          ddocs.isDevelopmentViews = params.type === 'development';
          return ddocs;
        });
      }, function (resp) {
        switch (resp.status) {
          case 404: return getEmptyViewsState();
          case 400: return getEmptyViewsState().then(function (emptyState) {
            emptyState.ddocsAreInFactMissing = resp.data.error === 'no_ddocs_service';
            return emptyState;
          });
          case 0: return $q.reject();
        }
      });
    };

    return mnViewsService;
  });