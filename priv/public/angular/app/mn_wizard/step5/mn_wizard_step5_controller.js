angular.module('mnWizard').controller('mnWizardStep5Controller',
  function ($scope, mnWizardStep5Service, mnWizardStep2Service, mnAuthService, mnHelper) {
    $scope.user = {
      username: 'Administrator',
      password: '',
      verifyPassword: ''
    };

    function reset() {
      $scope.focusMe = true;
      $scope.user.password = '';
      $scope.user.verifyPassword = '';
    }

    reset();

    function login(user) {
      return mnWizardStep5Service.postAuth(user).then(function () {
        return mnAuthService.manualLogin(user).then(function () {
          if (mnWizardStep2Service.isSomeBucketSelected()) {
            return mnWizardStep2Service.installSampleBuckets()
          }
        });
      });
    }

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }
      $scope.form.$setValidity('equals', $scope.user.password === $scope.user.verifyPassword);

      if ($scope.form.$invalid) {
        return reset();
      }

      var promise = login($scope.user);
      mnHelper.rejectReasonToScopeApplyer($scope, promise);
      mnHelper.handleSpinner($scope, promise, null, true);
      promise.then(mnHelper.reloadApp);
    }
  });