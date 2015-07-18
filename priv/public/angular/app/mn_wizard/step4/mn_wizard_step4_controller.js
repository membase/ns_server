angular.module('mnWizard').controller('mnWizardStep4Controller',
  function ($scope, $state, mnWizardStep4Service, pools, mnPromiseHelper) {

    $scope.isEnterprise = pools.isEnterprise;

    $scope.register = {
      version: '',
      email: '',
      firstname: '',
      lastname: '',
      company: '',
      agree: true,
      version: pools.implementationVersion || 'unknown'
    };

    $scope.sendStats = true;

    $scope.onSubmit = function () {
      if ($scope.form.$invalid || $scope.viewLoading) {
        return;
      }

      $scope.register.email && mnWizardStep4Service.postEmail($scope.register);

      var promise = mnWizardStep4Service.postStats({sendStats: $scope.sendStats});
      mnPromiseHelper($scope, promise)
        .showErrorsSensitiveSpinner()
        .catchErrors()
        .getPromise()
        .then(function () {
          $state.go('app.wizard.step5');
        });
    };
  });