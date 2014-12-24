angular.module('mnViews').controller('mnViewsDeleteViewDialogController',
  function ($scope, $modalInstance, mnHelper, mnViewsService, currentDdocName, currentViewName, isSpatial) {
    $scope.currentDdocName = currentDdocName;
    $scope.currentViewName = currentViewName;
    $scope.maybeSpatial = isSpatial ? 'Spatial' : '';
    $scope.doDelete = function () {
      var url = mnViewsService.getDdocUrl($scope.views.bucketsNames.selected, currentDdocName);

      var promise = mnViewsService.getDdoc(url).then(function (presentDdoc) {
        delete presentDdoc[isSpatial ? 'spatial' : 'views'][currentViewName];
        return mnViewsService.createDdoc(url, presentDdoc);
      });

      mnHelper.handleSpinner($scope, promise, null, true);
      promise['finally'](function () {
        mnHelper.reloadState();
        $modalInstance.close();
      });
    };
  });
