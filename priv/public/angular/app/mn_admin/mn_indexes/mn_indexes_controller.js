angular.module('mnIndexes', [
  'mnHelper',
  'mnIndexesService',
  'mnSortableTable'
]).controller('mnIndexesController',
  function ($scope, mnIndexesService, mnHelper, indexesState) {

    function applyIndexesState(indexesState) {
      console.log(indexesState)
      $scope.indexesState = indexesState;
    }

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