angular.module('mnLogs', [
  'mnLogsService',
  'mnPromiseHelper',
  'mnPoll',
  'mnPoolDefault',
  'mnSpinner'
]).controller('mnLogsController',
  function ($scope, mnHelper, mnLogsService, mnPoolDefault) {
    $scope.mnPoolDefault = mnPoolDefault.latestValue();
  });