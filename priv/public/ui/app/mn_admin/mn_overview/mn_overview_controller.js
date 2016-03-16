(function () {
  "use strict";

  angular.module('mnOverview', [
    'mnOverviewService',
    'mnBarUsage',
    'mnPlot',
    'mnServersService',
    'mnBucketsService',
    'mnPoll',
    'ui.bootstrap'
  ]).controller('mnOverviewController', mnOverviewController);

  function mnOverviewController($scope, mnServersService, mnBucketsService, mnOverviewService, mnPoller, mnAlertsService) {
    var vm = this;

    vm.alerts = mnAlertsService.alerts;
    vm.closeAlert = mnAlertsService.closeAlert;

    activate();

    function activate() {
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