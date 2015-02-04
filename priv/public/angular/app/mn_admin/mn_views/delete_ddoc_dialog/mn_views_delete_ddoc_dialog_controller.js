angular.module('mnViews').controller('mnViewsDeleteDdocDialogController',
  function ($scope, $modalInstance, mnHelper, mnViewsService, currentDdocName) {
    $scope.currentDdocName = currentDdocName;
    $scope.doDelete = function () {
      var url = mnViewsService.getDdocUrl($scope.views.bucketsNames.selected, currentDdocName);
      var promise = mnViewsService.deleteDdoc(url);
      mnHelper.handleModalAction($scope, promise, $modalInstance);
    };
  });
