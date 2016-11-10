(function () {
  "use strict";

  angular.module('mnOverview', [
    'mnOverviewService',
    'mnBarUsage',
    'mnPlot',
    'mnServersService',
    'mnBucketsService',
    'mnPoll',
    'ui.bootstrap',
    'mnElementCrane',
    'mnAboutDialogService',
    'mnPromiseHelper'
  ]).controller('mnOverviewController', mnOverviewController);

  function mnOverviewController($scope, mnServersService, mnBucketsService, mnOverviewService, mnPoller, mnAboutDialogService, mnPromiseHelper) {
    var vm = this;

    activate();

    function activate() {
      mnPromiseHelper(vm, mnAboutDialogService.getState())
        .applyToScope("aboutState");

      new mnPoller($scope, mnOverviewService.getOverviewConfig)
        .reloadOnScopeEvent("mnPoolDefaultChanged")
        .subscribe("mnOverviewConfig", vm)
        .cycle();
      new mnPoller($scope, function () {
          return mnServersService.getNodes();
        })
        .reloadOnScopeEvent("nodesChanged")
        .subscribe("nodes", vm)
        .cycle();
      new mnPoller($scope, function () {
          return mnBucketsService.getBucketsByType();
        })
        .reloadOnScopeEvent("bucketUriChanged")
        .subscribe("buckets", vm)
        .cycle();

      if ($scope.rbac.cluster.bucket['*'].stats.read) {
        new mnPoller($scope, mnOverviewService.getStats)
          .setInterval(3000)
          .subscribe("mnOverviewStats", vm)
          .cycle();
      }
    }
  }
})();
