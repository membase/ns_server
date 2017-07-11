(function () {
  "use strict";

  angular
    .module('mnBucketsForm', [
      'mnFocus',
      'mnBucketsDetailsService',
      'mnFilters',
      'mnAutocompleteOff',
      'mnPromiseHelper',
      'mnBarUsage',
      'mnUserRolesService'
    ])
    .directive('mnBucketsForm', mnBucketsFormDirective);

  function mnBucketsFormDirective($http, mnBucketsDetailsDialogService, mnPromiseHelper, mnUserRolesService) {

    var mnBucketsForm = {
      restrict: 'A',
      scope: {
        bucketConf: '=',
        autoCompactionSettings: '=',
        validation: '=',
        poolDefault: '=?',
        pools: '=',
        rbac: '='
      },
      isolate: false,
      replace: true,
      templateUrl: 'app/components/directives/mn_buckets_form/mn_buckets_form.html',
      controller: controller
    };

    return mnBucketsForm;

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
    function controller($scope) {
      $scope.replicaNumberEnabled = $scope.bucketConf.replicaNumber != 0;
      $scope.canChangeBucketsSettings = $scope.bucketConf.isNew;

      if ($scope.rbac && $scope.rbac.cluster.admin.security.read) {
        mnUserRolesService.getUsers().then(function (users) {
          var interestedRoles = {
            "admin": " (read/write)",
            "cluster_admin": " (read/write)",
            "ro_admin": " (read)",
            "bucket_admin*": " (read/write)"
          };
          var users1 = _.reduce(users.data, function (acc, user) {
            var role1 = _.find(user.roles, function (role) {
              return interestedRoles[role.role + (role.bucket_name || "")];
            });
            if (role1) {
              acc.push(user.id + interestedRoles[role1.role + (role1.bucket_name || "")]);
            }
            return acc;
          }, []);
          $scope.users = users1;
        });
      }

      $scope.$watch('replicaNumberEnabled', function (isEnabled) {
        if (!isEnabled) {
          $scope.bucketConf.replicaNumber = 0;
          $scope.bucketConf.replicaIndex = 0;
        } else {
          $scope.bucketConf.replicaNumber = Number($scope.bucketConf.replicaNumber) || 1;
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
        mnPromiseHelper($scope, $http({
          method: 'POST',
          url: bucketConf.uri,
          data: mnBucketsDetailsDialogService.prepareBucketConfigForSaving(bucketConf, autoCompactionSettings, $scope.poolDefault, $scope.pools),
          params: {
            just_validate: 1,
            ignore_warnings: $scope.bucketConf.ignoreWarnings ? 1 : 0
          }
        }))
        .getPromise()
        .then(adaptValidationResult, adaptValidationResult)
        .then(function (result) {
          $scope.validation.result = result;
        });
      }, true);
    }
  }
})();
