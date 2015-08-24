angular.module('mnXDCR').controller('mnXDCRCreateDialogController',
  function ($scope, $modalInstance, $timeout, $window, mnPromiseHelper, mnXDCRService, buckets, replicationSettings, mnRegexService) {
    $scope.replication = replicationSettings.data;
    delete $scope.replication.socketOptions;
    $scope.replication.replicationType = "continuous";
    $scope.replication.type = "xmem";
    $scope.buckets = buckets.byType.membase;
    $scope.replication.fromBucket = $scope.buckets[0].name;
    $scope.replication.toCluster = $scope.mnXdcrState.references[0].name;
    $scope.advancedFiltering = {};

    try {
      $scope.advancedFiltering.filterExpression = $window.localStorage.getItem('mn_xdcr_regex');
      $scope.advancedFiltering.testKey = JSON.parse($window.localStorage.getItem('mn_xdcr_testKeys'))[0];
    } catch (e) {}

    mnRegexService.handleValidateRegex($scope, $scope.advancedFiltering);

    $scope.createReplication = function () {
      if ($scope.replication.enableAdvancedFiltering) {
        var filterExpression = $scope.advancedFiltering.filterExpression;
      }
      var replication = mnXDCRService.removeExcessSettings($scope.replication);
      replication.filterExpression = filterExpression;
      var promise = mnXDCRService.postRelication(replication);
      mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
