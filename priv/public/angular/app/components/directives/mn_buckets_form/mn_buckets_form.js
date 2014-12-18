angular.module('mnBucketsForm').directive('mnBucketsForm', function (mnHttp, mnBucketsDetailsService, mnBytesToMBFilter, mnCountFilter) {

  function threadsEvictionWarning(scope, value) {
    var initialValue = scope.bucketConf[value];
    scope.$watch('bucketConf.' + value, function (newValue) {
      if (initialValue != newValue) {
        scope[value + 'Warning'] = 'Changing ' + (value === 'evictionPolicy' ? 'eviction policy' : 'bucket priority')  +
                                   ' will restart the bucket. This will lead to closing all open connections and some downtime';
      } else {
        scope[value + 'Warning'] = ''
      }
    });
  }

  return {
    restrict: 'A',
    scope: {
      bucketConf: '='
    },
    isolate: false,
    replace: true,
    templateUrl: 'components/directives/mn_buckets_form/mn_buckets_form.html',
    controller: function ($scope) {
      $scope.replicaNumberEnabled = $scope.bucketConf.replicaNumber != 0;
      $scope.canChangeBucketsSettings = !($scope.bucketConf.isNew && !$scope.bucketConf.isWizard);
      $scope.focusMe = true;

      $scope.$watch('replicaNumberEnabled', function (isEnabled) {
        if (!isEnabled) {
          $scope.bucketConf.replicaNumber = 0;
          $scope.bucketConf.replicaIndex = 0;
        } else {
          $scope.bucketConf.replicaNumber = 1;
        }
      });

      if (!$scope.bucketConf.isNew && !$scope.bucketConf.isWizard) {
        threadsEvictionWarning($scope, 'threadsNumber');
        threadsEvictionWarning($scope, 'evictionPolicy');
      }

      function onResult(resp) {
        var result = resp.data;
        var ramSummary = result.summaries.ramSummary;

        $scope.validationResult = {
          totalBucketSize: mnBytesToMBFilter(ramSummary.thisAlloc),
          nodeCount: mnCountFilter(ramSummary.nodesCount, 'node'),
          perNodeMegs: ramSummary.perNodeMegs,
          guageConfig: mnBucketsDetailsService.getBucketRamGuageConfig(ramSummary),
          errors: result.errors
        };
      }

      $scope.$watch('bucketConf', function () {
        mnHttp({
          method: 'POST',
          url: $scope.bucketConf.uri,
          data: $scope.bucketConf,
          params: {
            just_validate: 1
          }
        }).then(onResult, onResult);
      }, true);
    }
  };
});