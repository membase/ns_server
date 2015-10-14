angular.module('mnAutoCompactionForm', [
  'mnHttp',
  'mnPoolDefault'
]).directive('mnAutoCompactionForm', function (mnHttp, mnPoolDefault) {

  return {
    restrict: 'A',
    scope: {
      autoCompactionSettings: '=',
      validationErrors: '='
    },
    isolate: false,
    replace: true,
    templateUrl: 'components/directives/mn_auto_compaction_form/mn_auto_compaction_form.html',
    controller: function ($scope) {
      $scope.mnPoolDefault = mnPoolDefault.latestValue();
      if ($scope.mnPoolDefault.isROAdminCreds) {
        return;
      }
      $scope.$watch('validationErrors', function (errors) {
        angular.forEach($scope.validationErrors, function (value, key) {
          $scope.validationErrors[key.replace('[', '_').replace(']', '_')] = value;
        });
        $scope.errors = $scope.validationErrors;
      });
    }
  };
});