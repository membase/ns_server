angular.module('mnWizard').controller('mnWizardStep5Controller',
  function ($scope, $state, mnPools, mnWizardStep5Service, mnWizardStep2Service, mnAuthService, mnHelper, mnAlertsService) {
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
        return mnAuthService.login(user).then(function () {
          return mnPools.getFresh().then(function () {
            $state.go('app.admin.overview');
            if (mnWizardStep2Service.isSomeBucketSelected()) {
              return mnWizardStep2Service.installSampleBuckets().then(null, function (resp) {
                mnAlertsService.formatAndSetAlerts(resp.data, 'danger');
              });
            }
          });
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
      mnHelper
        .promiseHelper($scope, promise)
        .showErrorsSensitiveSpinner()
        .catchErrors();
    }
  });