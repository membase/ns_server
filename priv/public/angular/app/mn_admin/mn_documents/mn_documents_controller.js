(function () {
  "use strict";

  angular
    .module("mnDocuments", [
      "mnDocumentsListService",
      "mnDocumentsEditingService",
      "mnPromiseHelper",
      "mnFilter",
      "ui.router",
      "ui.bootstrap",
      "ui.codemirror",
      "mnSpinner",
      "ngMessages",
      "mnPoll"
    ])
    .controller("mnDocumentsController", mnDocumentsController);

  function mnDocumentsController($scope, mnDocumentsListService, mnPromiseHelper, $state) {
    var vm = this;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnDocumentsListService.populateBucketsSelectBox($state.params))
        .cancelOnScopeDestroy($scope)
        .applyToScope("mnDocumentsState");
    }

    $scope.$watch('mnDocumentsController.mnDocumentsState.bucketsNames.selected', function (selectedBucket) {
      selectedBucket && selectedBucket !== $state.params.documentsBucket && $state.go('app.admin.documents.list', {
        documentsBucket: selectedBucket,
        pageNumber: 0
      });
    });
  }
})();
