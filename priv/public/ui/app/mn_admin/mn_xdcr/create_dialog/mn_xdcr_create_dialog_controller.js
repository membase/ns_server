angular.module('mnXDCR').controller('mnXDCRCreateDialogController',
  function ($scope, $modalInstance, $timeout, $window, mnPromiseHelper, mnPoolDefault, mnXDCRService, buckets, replicationSettings, mnRegexService) {
    $scope.replication = replicationSettings.data;
    $scope.mnPoolDefault = mnPoolDefault.latestValue();
    delete $scope.replication.socketOptions;
    $scope.replication.replicationType = "continuous";
    $scope.replication.type = "xmem";
    $scope.buckets = buckets.byType.membase;
    $scope.replication.fromBucket = $scope.buckets[0].name;
    $scope.replication.toCluster = $scope.mnXdcrState.references[0].name;
    $scope.advancedFiltering = {};

    if ($scope.mnPoolDefault.value.isEnterprise) {
      try {
        $scope.advancedFiltering.filterExpression = $window.localStorage.getItem('mn_xdcr_regex');
        $scope.advancedFiltering.testKey = JSON.parse($window.localStorage.getItem('mn_xdcr_testKeys'))[0];
      } catch (e) {}

      mnRegexService.handleValidateRegex($scope, $scope.advancedFiltering);
    }

    $scope.createReplication = function () {
      var replication = mnXDCRService.removeExcessSettings($scope.replication);
      if ($scope.mnPoolDefault.value.isEnterprise) {
        if ($scope.replication.enableAdvancedFiltering) {
          var filterExpression = $scope.advancedFiltering.filterExpression;
        }
        replication.filterExpression = filterExpression;
      }
      var promise = mnXDCRService.postRelication(replication);
      mnPromiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .cancelOnScopeDestroy()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
