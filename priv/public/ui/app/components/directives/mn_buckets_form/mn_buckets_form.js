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
    function addBucketSpecificRoles(obj, name) {
      obj["bucket_admin" + name] = " (read/write)";
      obj["fts_searcher" + name] = " (read)";
      obj["fts_admin" + name] = " (read)";
      obj["query_manage_index" + name] = " (read)";
      obj["query_delete" + name] = " (read)";
      obj["query_insert"  + name] = " (read)";
      obj["query_update" + name] = " (read)";
      obj["query_select" + name] = " (read)";
      obj["views_admin" + name] = " (read)";
    }
    function controller($scope) {
      $scope.replicaNumberEnabled = $scope.bucketConf.replicaNumber != 0;
      $scope.canChangeBucketsSettings = $scope.bucketConf.isNew;

      if ($scope.rbac && $scope.rbac.cluster.admin.security.read) {
        mnUserRolesService.getUsers().then(function (users) {
          if (users.data.length == 0) {
            $scope.users = [];
            return;
          }
          var interestingRoles = {
            "admin": " (read/write)",
            "cluster_admin": " (read/write)",
            "ro_admin": " (read)",
            "replication_admin": " (read)",
            "query_external_access": " (read)",
            "query_system_catalog": " (read)"
          };
          addBucketSpecificRoles(interestingRoles, "*");
          if (!$scope.bucketConf.isNew) {
            addBucketSpecificRoles(interestingRoles, $scope.bucketConf.name);
          }
          var users1 = _.reduce(users.data, function (acc, user) {
            user.roles = _.sortBy(user.roles, "role");
            var role1 = _.find(user.roles, function (role) {
              return interestingRoles[role.role + (role.bucket_name || "")];
            });
            if (role1) {
              acc.push(user.id + interestingRoles[role1.role + (role1.bucket_name || "")]);
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
