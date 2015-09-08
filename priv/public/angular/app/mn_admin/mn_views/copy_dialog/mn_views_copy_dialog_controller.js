angular.module('mnViews').controller('mnViewsCopyDialogController',
  function ($scope, $modal, $state, mnViewsService, mnPromiseHelper, $modalInstance, currentDdoc) {
    $scope.ddoc = {};
    $scope.ddoc.name = mnViewsService.cutOffDesignPrefix(currentDdoc.meta.id);
    function prepareToCopy(url, ddoc) {
      return function () {
        return mnPromiseHelper($scope, mnViewsService.createDdoc(url, ddoc.json), $modalInstance)
          .closeOnSuccess()
          .cancelOnScopeDestroy()
          .onSuccess(function () {
            $state.go('app.admin.views', {
              type: 'development'
            });
          })
          .getPromise();
      };
    }
    $scope.onSubmit = function () {
      var url = mnViewsService.getDdocUrl($scope.mnViewsState.bucketsNames.selected, "_design/dev_" + $scope.ddoc.name);
      var copy = prepareToCopy(url, currentDdoc);
      var promise = mnViewsService.getDdoc(url).then(function (presentDdoc) {
        return $modal.open({
          templateUrl: 'mn_admin/mn_views/confirm_dialogs/mn_views_confirm_override_dialog.html'
        }).result.then(copy);
      }, copy);

      mnPromiseHelper($scope, promise)
        .showSpinner()
        .cancelOnScopeDestroy();
    };
  });
