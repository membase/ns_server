angular.module('mnViews').controller('mnViewsCopyDialogController',
  function ($scope, $modal, $state, mnViewsService, mnPromiseHelper, $modalInstance, currentDdoc) {
    $scope.ddoc = {};
    $scope.ddoc.name = mnViewsService.cutOffDesignPrefix(currentDdoc.meta.id);
    function prepareToCopy(url, ddoc) {
      return function () {
        return mnViewsService.createDdoc(url, ddoc.json).then(function () {
          $modalInstance.close();
          $state.go('app.admin.views', {
            type: 'development'
          });
        });
      };
    }
    $scope.onSubmit = function () {
      var url = mnViewsService.getDdocUrl($scope.mnViewsState.bucketsNames.selected, "_design/dev_" + $scope.ddoc.name);
      var copy = prepareToCopy(url, currentDdoc);
      var promise = mnViewsService.getDdoc(url).then(function (presentDdoc) {
        return $modal.open({
          templateUrl: '/angular/app/mn_admin/mn_views/confirm_dialogs/mn_views_confirm_override_dialog.html'
        }).result.then(copy);
      }, copy);

      mnPromiseHelper($scope, promise).showSpinner();
    };
  });
