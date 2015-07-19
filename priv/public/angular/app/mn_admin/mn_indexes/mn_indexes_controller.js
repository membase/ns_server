angular.module('mnIndexes', [
  'mnHelper',
  'mnIndexesService',
  'mnSortableTable',
  'mnPoll'
]).controller('mnIndexesController',
  function ($scope, mnIndexesService, mnHelper, indexesState, mnPoll) {

    function applyIndexesState(indexesState) {
      console.log(indexesState)
      $scope.indexesState = indexesState;
    }

    applyIndexesState(indexesState);

    mnPoll.start($scope, function () {
      return mnIndexesService.getIndexesState();
    }).subscribe(applyIndexesState);

    mnHelper.initializeDetailsHashObserver($scope, 'openedIndex', 'app.admin.indexes');
    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);

  });