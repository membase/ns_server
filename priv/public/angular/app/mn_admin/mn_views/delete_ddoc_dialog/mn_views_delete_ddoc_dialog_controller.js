angular.module('mnViews').controller('mnViewsDeleteDdocDialogController',
  function ($scope, $modalInstance, mnViewsService, currentDdocName, mnPromiseHelper) {
    $scope.currentDdocName = currentDdocName;
    $scope.doDelete = function () {
      var url = mnViewsService.getDdocUrl($scope.views.bucketsNames.selected, currentDdocName);
      var promise = mnViewsService.deleteDdoc(url);
      mnPromiseHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
