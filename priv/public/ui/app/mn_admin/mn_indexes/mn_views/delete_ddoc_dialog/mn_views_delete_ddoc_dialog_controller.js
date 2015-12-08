(function () {
  "use strict";

  angular
    .module("mnViews")
    .controller("mnViewsDeleteDdocDialogController", mnViewsDeleteDdocDialogController);

  function mnViewsDeleteDdocDialogController($scope, $state, $uibModalInstance, mnViewsListService, currentDdocName, mnPromiseHelper) {
    var vm = this;
    vm.currentDdocName = currentDdocName;
    vm.doDelete = doDelete;

    function doDelete() {
      var url = mnViewsListService.getDdocUrl($state.params.viewsBucket, currentDdocName);
      var promise = mnViewsListService.deleteDdoc(url);
      mnPromiseHelper.handleModalAction($scope, promise, $uibModalInstance, vm);
    }
  }
})();
