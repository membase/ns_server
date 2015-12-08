(function () {
  "use strict";

  angular
    .module("mnViews")
    .controller("mnViewsDeleteViewDialogController", mnViewsDeleteViewDialogController);

  function mnViewsDeleteViewDialogController($scope, $state, $uibModalInstance, mnPromiseHelper, mnViewsListService, currentDdocName, currentViewName, isSpatial) {
    var vm = this;
    vm.currentDdocName = currentDdocName;
    vm.currentViewName = currentViewName;
    vm.maybeSpatial = isSpatial ? 'Spatial' : '';
    vm.doDelete = doDelete;

    function doDelete() {
      var url = mnViewsListService.getDdocUrl($state.params.viewsBucket, currentDdocName);

      var promise = mnViewsListService.getDdoc(url).then(function (presentDdoc) {
        delete presentDdoc.json[isSpatial ? 'spatial' : 'views'][currentViewName];
        return mnPromiseHelper(vm, mnViewsListService.createDdoc(url, presentDdoc.json))
          .cancelOnScopeDestroy($scope)
          .getPromise();
      });

      mnPromiseHelper.handleModalAction($scope, promise, $uibModalInstance, vm);
    };
  }
})();
