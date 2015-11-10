angular.module('mnIndexes', [
  'mnHelper',
  'mnIndexesService',
  'mnSortableTable',
  'mnPoll',
  'mnSpinner'
]).controller('mnIndexesController',
  function ($scope, mnIndexesService, mnHelper, mnPoller) {

    new mnPoller($scope, mnIndexesService.getIndexesState)
      .subscribe("mnIndexesState")
      .keepIn("app.admin.indexes")
      .cancelOnScopeDestroy()
      .cycle();

    mnHelper.initializeDetailsHashObserver($scope, 'openedIndex', 'app.admin.indexes');

  });