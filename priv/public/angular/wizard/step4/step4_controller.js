angular.module('wizard')
  .controller('wizard.step4.Controller', ['$scope', '$state', 'wizard.step4.service', 'auth.service',
    function ($scope, $state, step4Service, authService) {
      $scope.focusMe = true;

      step4Service.model.register.version = authService.version || 'unknown';
      $scope.modelStep4Service = step4Service.model;

      $scope.onSubmit = function onSubmit() {
        if ($scope.form.$invalid || $scope.spinner) {
          return;
        }
        $scope.spinner = true;

        $scope.modelStep4Service.register.email && step4Service.postEmail();

        step4Service.postStats().success(function () {
          $scope.spinner = false;
          $state.transitionTo('wizard.step5');
        }).error(function (errors) {
          $scope.spinner = false;
          $scope.errors = errors;
        });
      };
    }]);