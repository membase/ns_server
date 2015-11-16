(function () {
  "use strict";

  angular.module('mnXDCR').controller('mnXDCRReferenceDialogController', mnXDCRReferenceDialogController);

  function mnXDCRReferenceDialogController($scope, $uibModalInstance, mnPromiseHelper, mnXDCRService, reference, mnPoolDefault) {
    var vm = this;

    vm.cluster = reference ? _.clone(reference) : {username: 'Administrator'};
    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.createClusterReference = createClusterReference;

    function createClusterReference() {
      var promise = mnXDCRService.saveClusterReference(vm.cluster, reference && reference.name);
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .cancelOnScopeDestroy($scope)
        .closeOnSuccess()
        .reloadState();
    };
  }
})();

