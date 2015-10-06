(function () {
  "use strict";

  angular
    .module("mnViews")
    .controller("mnViewsCopyDialogController", mnViewsCopyDialogController);

  function mnViewsCopyDialogController($scope, $modal, $state, mnViewsListService, mnPromiseHelper, $modalInstance, currentDdoc) {
    var vm = this;

    vm.ddoc = {};
    vm.ddoc.name = mnViewsListService.cutOffDesignPrefix(currentDdoc.meta.id);
    vm.onSubmit = onSubmit;

    function onSubmit() {
      var url = mnViewsListService.getDdocUrl($state.params.viewsBucket, "_design/dev_" + encodeURIComponent(vm.ddoc.name));
      var copy = prepareToCopy(url, currentDdoc);
      var promise = mnViewsListService.getDdoc(url).then(function (presentDdoc) {
        return $modal.open({
          templateUrl: 'mn_admin/mn_views/confirm_dialogs/mn_views_confirm_override_dialog.html'
        }).result.then(copy);
      }, copy);

      mnPromiseHelper(vm, promise)
        .showSpinner()
        .cancelOnScopeDestroy($scope);
    }
    function prepareToCopy(url, ddoc) {
      return function () {
        return mnPromiseHelper(vm, mnViewsListService.createDdoc(url, ddoc.json), $modalInstance)
          .closeOnSuccess()
          .cancelOnScopeDestroy($scope)
          .onSuccess(function () {
            $state.go('app.admin.views.list', {
              type: 'development'
            });
          })
          .getPromise();
      };
    }
  }
})();
