angular.module('mnLogs', [
  'mnLogsService',
  'mnPromiseHelper',
  'mnPoll',
  'mnPoolDefault'
]).controller('mnLogsController',
  function ($scope, mnHelper, mnLogsService, mnPoolDefault) {
    $scope.mnPoolDefault = mnPoolDefault.latestValue();
  });