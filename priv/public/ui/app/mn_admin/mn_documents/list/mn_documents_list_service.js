(function () {
  "use strict";

  angular
    .module("mnDocumentsListService", ["mnBucketsService"])
    .factory("mnDocumentsListService", mnDocumentsListFactory);

  function mnDocumentsListFactory($http, $q, mnBucketsService, docsLimit) {
    var mnDocumentsListService = {
      getDocuments: getDocuments,
      getDocumentsListState: getDocumentsListState,
      populateBucketsSelectBox: populateBucketsSelectBox,
      getDocumentsParams: getDocumentsParams,
      getDocumentsURI: getDocumentsURI
    };

    return mnDocumentsListService;

    function populateBucketsSelectBox(params) {
      return mnBucketsService.getBucketsByType().then(function (buckets) {
        var rv = {};
        var bucket
        rv.bucketsNames =
          buckets.byType.membase.names
          .concat(buckets.byType.ephemeral.names);

        rv.currentBucket = buckets.find(function (bucket) {
          return bucket.name == params.bucket;
        });
        rv.bucketsNames.selected = params.bucket;
        return rv;
      });
    }

    function getListState(docs, params) {
      var rv = {};
      rv.pageNumber = params.pageNumber;
      rv.isNextDisabled = docs.rows.length <= params.pageLimit || params.pageLimit * (params.pageNumber + 1) === docsLimit;
      if (docs.rows.length > params.pageLimit) {
        docs.rows.pop();
      }

      rv.docs = docs;

      rv.pageLimits = [5, 10, 20, 50, 100];
      rv.pageLimits.selected = params.pageLimit;
      return rv;
    }

    function getDocumentsListState(params) {
      params.pageLimit = params.pageLimit || 5;
      return getDocuments(params).then(function (resp) {
        return getListState(resp.data, params);
      }, function (resp) {
        switch (resp.status) {
          case 404: return getEmptyListState(params, {data: {error: "bucket not found"}});
          default: return getEmptyListState(params, resp);
        }
      });
    }

    function getEmptyListState(params, resp) {
      var rv = getListState({rows: [], errors: [resp && resp.data]}, params);
      rv.isEmptyState = true;
      return rv;
    }

    function getDocumentsParams(params) {
      var param;
      try {
        param = JSON.parse(params.documentsFilter) || {};
      } catch (e) {
        param = {};
      }
      var page = params.pageNumber;
      var limit = params.pageLimit;
      var skip = page * limit;

      param.skip = String(skip);
      param.include_docs = true;
      param.limit = String(limit + 1);

      if (param.startkey) {
        param.startkey = JSON.stringify(param.startkey);
      }

      if (param.endkey) {
        param.endkey = JSON.stringify(param.endkey);
      }
      return param;
    }

    function getDocumentsURI(params) {
      return "/pools/default/buckets/" + encodeURIComponent(params.bucket) + "/docs";
    }

    function getDocuments(params) {
      return $http({
        method: "GET",
        url: getDocumentsURI(params),
        params: getDocumentsParams(params)
      });
    }
  }
})();
