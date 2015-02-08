angular.module('mnXDCR').controller('mnXDCRCreateDialogController',
  function ($scope, $modalInstance, mnHelper, mnXDCRService, buckets, replicationSettings) {
    $scope.replication = replicationSettings.data;
    delete $scope.replication.socketOptions;
    $scope.replication.replicationType = "continuous";
    $scope.replication.type = "xmem";
    $scope.buckets = buckets.byType.membase;
    $scope.replication.fromBucket = $scope.buckets[0].name;
    $scope.replication.toCluster = $scope.xdcr.references[0].name;

    $scope.createReplication = function () {
      var promise = mnXDCRService.postRelication(mnXDCRService.removeExcessSettings($scope.replication));
      mnHelper
        .promiseHelper($scope, promise, $modalInstance)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .closeOnSuccess()
        .reloadState();
    };
  });
