(function () {
  "use strict";

  angular
    .module("mnDocumentsEditingService", ["mnHttp", "mnBucketsService", "mnFilters"])
    .factory("mnDocumentsEditingService", mnDocumentsEditingFactory);

  function mnDocumentsEditingFactory(mnHttp, mnBucketsService, $q, getStringBytesFilter, docBytesLimit) {
    var mnDocumentsEditingService = {
      getDocument: getDocument,
      createDocument: createDocument,
      deleteDocument: deleteDocument,
      getDocumentsEditingState: getDocumentsEditingState,
      isJsonOverLimited: isJsonOverLimited
    };

    return mnDocumentsEditingService;

    function isJsonOverLimited(json) {
      return getStringBytesFilter(json) > docBytesLimit;
    }

    function getDocumentsEditingState(params) {
      return getDocument(params).then(function getDocumentState(resp) {
        var doc = resp.data
        var rv = {};
        var editorWarnings = {
          documentIsBase64: ("base64" in doc),
          documentLimitError: isJsonOverLimited(JSON.stringify(doc.json))
        };
        rv.title = doc.meta.id;
        if (_.chain(editorWarnings).values().some().value()) {
          rv.editorWarnings = editorWarnings;
        } else {
          rv.doc = JSON.stringify(doc.json, null, "  ");
        }
        return rv;
      }, function (resp) {
        switch (resp.status) {
          case 404: return {
            editorWarnings: {
              notFound: true
            },
            title: params.documentId
          };
          case 503:
          case 500: return {
            errors: resp && resp.data,
          };
        }
      });
    }

    function deleteDocument(params) {
      return mnHttp({
        method: "DELETE",
        url: buildDocumentUrl(params)
      });
    }
    function createDocument(params, doc) {
      return mnHttp({
        method: "POST",
        mnHttp: {
          isNotForm: true
        },
        url: buildDocumentUrl(params),
        data: doc || { "click": "to edit", "with JSON": "there are no reserved field names" }
      });
    }
    function getDocument(params) {
      if (!params.documentId) {
        return $q.reject({data: {reason: "Document ID cannot be empty"}});
      }
      return mnHttp({
        method: "GET",
        url: buildDocumentUrl(params)
      });
    }
    function buildDocumentUrl(params) {
      return "/pools/default/buckets/" + encodeURIComponent(params.documentsBucket) + "/docs/" + encodeURIComponent(params.documentId);
    }
  }
})();
