(function () {
  "use strict";

  angular
    .module("mnDocuments", [
      "mnDocumentsListService",
      "mnDocumentsEditingService",
      "mnPromiseHelper",
      "mnFilter",
      "mnFilters",
      "ui.router",
      "ui.bootstrap",
      "ui.codemirror",
      "mnSpinner",
      "ngMessages",
      "mnPoll",
      "mnElementCrane"
    ])
    .controller("mnDocumentsController", mnDocumentsController);

  function mnDocumentsController($scope, mnDocumentsListService, mnPromiseHelper, $state, mnPoller) {
    var vm = this;

    vm.onSelectBucketName = onSelectBucketName;

    activate();

    function onSelectBucketName(selectedBucket) {
      $state.go('^.list', {
        bucket: selectedBucket,
        pageNumber: 0
      });
    }

    function activate() {
      new mnPoller($scope, function () {
          return mnDocumentsListService.populateBucketsSelectBox($state.params);
        })
        .subscribe("state", vm)
        .reloadOnScopeEvent("bucketUriChanged")
        .cycle();
    }
  }
})();
