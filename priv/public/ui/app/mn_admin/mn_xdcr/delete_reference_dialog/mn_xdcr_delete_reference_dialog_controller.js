(function () {
  "use strict";

  angular.module('mnXDCR').controller('mnXDCRDeleteReferenceDialogController', mnXDCRDeleteReferenceDialogController);

  function mnXDCRDeleteReferenceDialogController($scope, $uibModalInstance, mnPromiseHelper, mnXDCRService, name) {
    var vm = this;

    vm.name = name;
    vm.deleteClusterReference = deleteClusterReference;

    function deleteClusterReference() {
      var promise = mnXDCRService.deleteClusterReference(name);
      mnPromiseHelper.handleModalAction($scope, promise, $uibModalInstance, vm);
    }
  }
})();
