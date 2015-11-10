angular.module('mnOverview', [
  'mnOverviewService',
  'mnBarUsage',
  'mnPlot',
  'mnHelper',
  'mnServersService',
  'mnBucketsService',
  'mnPromiseHelper',
  'mnPoll'
]).controller('mnOverviewController',
  function ($scope, mnServersService, mnBucketsService, mnOverviewService, mnHelper, mnPoller, mnPromiseHelper) {

    new mnPoller($scope, mnOverviewService.getStats)
      .setExtractInterval(3000)
      .subscribe("mnOverviewStats")
      .cancelOnScopeDestroy()
      .cycle();
    new mnPoller($scope, mnOverviewService.getOverviewConfig)
      .setExtractInterval(3000)
      .subscribe("mnOverviewConfig")
      .cancelOnScopeDestroy()
      .cycle();

    mnPromiseHelper($scope, mnServersService.getNodes())
      .applyToScope("nodes")
      .cancelOnScopeDestroy();
    mnPromiseHelper($scope, mnBucketsService.getBucketsByType())
      .applyToScope("buckets")
      .cancelOnScopeDestroy();

  });