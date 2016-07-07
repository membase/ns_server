(function () {
  "use strict";

  angular
    .module('mnBuckets')
    .controller('mnBucketsDeleteDialogController', mnBucketsDeleteDialogController);

  function mnBucketsDeleteDialogController($scope, $uibModalInstance, bucket, mnHelper, mnPromiseHelper, mnBucketsDetailsService, mnAlertsService) {
    var vm = this;
    vm.doDelete = doDelete;

    function doDelete() {
      var promise = mnBucketsDetailsService.deleteBucket(bucket);
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showErrorsSensitiveSpinner()
        .catchGlobalErrors()
        .closeFinally()
        .broadcast("reloadBucketsPoller");
    }
  }
})();
