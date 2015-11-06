(function () {
  "use strict";

  angular
    .module("mnDocuments")
    .controller("mnDocumentsDeleteDialogController", mnDocumentsDeleteDialogController);

  function mnDocumentsDeleteDialogController($scope, mnDocumentsEditingService, $state, documentId, $uibModalInstance, mnPromiseHelper) {
    var vm = this;
    vm.onSubmit = onSubmit;

    function onSubmit() {
      var promise = mnDocumentsEditingService.deleteDocument({
        documentsBucket: $state.params.documentsBucket,
        documentId: documentId
      });
      mnPromiseHelper.handleModalAction($scope, promise, $uibModalInstance);
    }
  }
})();
