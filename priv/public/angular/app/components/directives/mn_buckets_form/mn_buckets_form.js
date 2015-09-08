angular.module('mnBucketsForm', [
  'mnHttp',
  'mnBucketsDetailsService',
  'mnFilters',
  'mnPromiseHelper'
]).directive('mnBucketsForm', function (mnHttp, mnBucketsDetailsDialogService, mnBytesToMBFilter, mnCountFilter, mnPromiseHelper) {

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
      bucketConf: '=',
      autoCompactionSettings: '='
    },
    isolate: false,
    replace: true,
    templateUrl: 'components/directives/mn_buckets_form/mn_buckets_form.html',
    controller: function ($scope) {
      $scope.replicaNumberEnabled = $scope.bucketConf.replicaNumber != 0;
      $scope.canChangeBucketsSettings = $scope.bucketConf.isNew;
      $scope.focusMe = true;

      $scope.$watch('replicaNumberEnabled', function (isEnabled) {
        if (!isEnabled) {
          $scope.bucketConf.replicaNumber = 0;
          $scope.bucketConf.replicaIndex = 0;
        } else {
          $scope.bucketConf.replicaNumber = $scope.bucketConf.replicaNumber || 1;
        }
      });

      if (!$scope.bucketConf.isNew && !$scope.bucketConf.isWizard) {
        threadsEvictionWarning($scope, 'threadsNumber');
        threadsEvictionWarning($scope, 'evictionPolicy');
      }

      function adaptValidationResult(resp) {
        return mnBucketsDetailsDialogService.adaptValidationResult(resp.data);
      }

      $scope.$watch(function () {
        return {
          bucketConf: $scope.bucketConf,
          autoCompactionSettings: $scope.autoCompactionSettings
        };
      }, function (values) {
        var bucketConf = values.bucketConf;
        var autoCompactionSettings = values.autoCompactionSettings;
        mnPromiseHelper($scope, mnHttp({
          method: 'POST',
          url: bucketConf.uri,
          data: mnBucketsDetailsDialogService.prepareBucketConfigForSaving(bucketConf, autoCompactionSettings),
          params: {
            just_validate: 1,
            ignore_warnings: $scope.bucketConf.ignoreWarnings ? 1 : 0
          }
        }))
        .cancelOnScopeDestroy()
        .getPromise()
        .then(adaptValidationResult, adaptValidationResult)
        .then(function (result) {
          $scope.validationResult = result;
        });
      }, true);
    }
  };
});