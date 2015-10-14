angular.module('mnMemoryQuota', [
  'mnServices',
  'mnPoolDefault'
]).directive('mnMemoryQuota', function (mnPoolDefault) {

  return {
    restrict: 'A',
    scope: {
      config: '=mnMemoryQuota',
      errors: "="
    },
    templateUrl: 'components/directives/mn_memory_quota/mn_memory_quota.html',
    controller: function ($scope) {
      //hack for avoiding access to $parent scope from child scope via propery "$parent"
      //should be removed after implementation of Controller As syntax
      $scope.mnMemoryQuotaController = $scope;
      $scope.mnPoolDefault = mnPoolDefault.latestValue();
    }
  };
});