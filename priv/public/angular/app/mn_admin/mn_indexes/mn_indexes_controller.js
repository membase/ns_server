angular.module('mnIndexes', [
  'mnHelper',
  'mnIndexesService'
]).controller('mnIndexesController',
  function ($scope, mnIndexesService, mnHelper, indexesState) {

    function applyIndexesState(indexesState) {
      console.log(indexesState)
      $scope.indexesState = indexesState;
    }

    $scope.isOrderBy = function (orderBy) {
      return $scope.orderBy === orderBy;
    };

    $scope.setOrder = function (orderBy) {
      if (!$scope.isOrderBy(orderBy)) {
        $scope.invert = false;
      } else {
        $scope.invert = !$scope.invert;
      }
      $scope.orderBy = orderBy;
    };

    $scope.setOrder('hosts');

    applyIndexesState(indexesState);

    mnHelper.setupLongPolling({
      methodToCall: function () {
        return mnIndexesService.getIndexesState();
      },
      scope: $scope,
      onUpdate: applyIndexesState
    });

    mnHelper.initializeDetailsHashObserver($scope, 'openedIndex', 'app.admin.indexes');
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);

  });