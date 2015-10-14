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
      "mnPoll"
    ])
    .controller("mnDocumentsController", mnDocumentsController);

  function mnDocumentsController($scope, mnPoolDefault, mnDocumentsListService, mnPoll, $state) {
    var vm = this;

    vm.mnPoolDefault = mnPoolDefault.latestValue();
    if (vm.mnPoolDefault.isROAdminCreds) {
      return;
    }

    activate();

    function activate() {
      $scope.$watch('mnDocumentsController.mnDocumentsState.bucketsNames.selected', function (selectedBucket) {
        selectedBucket && selectedBucket !== $state.params.documentsBucket && $state.go('app.admin.documents.list', {
          documentsBucket: selectedBucket,
          pageNumber: 0
        });
      });
      mnPoll
        .start($scope, function () {
          return mnDocumentsListService.populateBucketsSelectBox($state.params);
        })
        .subscribe("mnDocumentsState", vm)
        .keepIn(null, vm)
        .cancelOnScopeDestroy()
        .run();
    }
  }
})();
