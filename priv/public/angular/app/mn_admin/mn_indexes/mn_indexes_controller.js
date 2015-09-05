angular.module('mnIndexes', [
  'mnHelper',
  'mnIndexesService',
  'mnSortableTable',
  'mnPoll'
]).controller('mnIndexesController',
  function ($scope, mnIndexesService, mnHelper, mnPoll) {

    mnPoll.start($scope, mnIndexesService.getIndexesState).subscribe("mnIndexesState").keepIn();

    mnHelper.initializeDetailsHashObserver($scope, 'openedIndex', 'app.admin.indexes');

  });