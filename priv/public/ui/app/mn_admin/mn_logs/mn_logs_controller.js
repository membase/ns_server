(function () {
  "use strict";

  angular.module('mnLogs', [
    'mnLogsService',
    'mnPromiseHelper',
    'mnPoll',
    'mnPoolDefault',
    'mnSpinner'
  ]).controller('mnLogsController', mnLogsController);

  function mnLogsController($scope, mnHelper, mnLogsService, mnPoolDefault) {
    var vm = this;
    vm.mnPoolDefault = mnPoolDefault.latestValue();
  }
})();
