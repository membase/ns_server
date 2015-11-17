(function () {
  "use strict";

  angular.module('mnOverview', [
    'mnOverviewService',
    'mnBarUsage',
    'mnPlot',
    'mnHelper',
    'mnServersService',
    'mnBucketsService',
    'mnPromiseHelper',
    'mnPoll'
  ]).controller('mnOverviewController', mnOverviewController);

  function mnOverviewController($scope, mnServersService, mnBucketsService, mnOverviewService, mnHelper, mnPoller, mnPromiseHelper) {
    var vm = this;

    activate();

    function activate() {
      new mnPoller($scope, mnOverviewService.getStats)
        .setExtractInterval(3000)
        .subscribe("mnOverviewStats", vm)
        .cancelOnScopeDestroy()
        .cycle();
      new mnPoller($scope, mnOverviewService.getOverviewConfig)
        .setExtractInterval(3000)
        .subscribe("mnOverviewConfig", vm)
        .cancelOnScopeDestroy()
        .cycle();

      mnPromiseHelper(vm, mnServersService.getNodes())
        .applyToScope("nodes")
        .cancelOnScopeDestroy($scope);
      mnPromiseHelper(vm, mnBucketsService.getBucketsByType())
        .applyToScope("buckets")
        .cancelOnScopeDestroy($scope);
    }
  }
})();