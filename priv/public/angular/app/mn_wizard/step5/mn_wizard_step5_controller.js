angular.module('mnWizard').controller('mnWizardStep5Controller',
  function ($scope, mnWizardStep5Service, mnWizardStep3Service, mnWizardStep2Service, mnAuthService) {
    $scope.mnWizardStep5ServiceModel = mnWizardStep5Service.model;
    var user = $scope.mnWizardStep5ServiceModel.user;

    function reset() {
      $scope.viewLoading = false;
      $scope.focusMe = true;
      user.password = undefined;
      user.verifyPassword = undefined;
    }

    reset();

    $scope.onSubmit = function () {
      if ($scope.viewLoading) {
        return;
      }
      $scope.viewLoading = true;
      $scope.form.$setValidity('userReq', !!user.username);
      $scope.form.$setValidity('equals', user.password === user.verifyPassword);
      $scope.form.$setValidity('passLength', user.password && user.password.length >= 6);

      if ($scope.form.$invalid) {
        return reset();
      }
      mnWizardStep5Service.postAuth().success(function () {
        mnAuthService.manualLogin($scope.mnWizardStep5ServiceModel.user).success(function () {
          mnWizardStep5Service.resetUserCreds();
          mnWizardStep3Service.postBuckets(false).success(function () {
            !_.isEmpty(mnWizardStep2Service.model.selected) && mnWizardStep2Service.installSampleBuckets().error(function () {
              // var errReason = errorObject && errorObject.reason || simpleErrors.join(' and ');
              // genericDialog({
              //   buttons: {ok: true},
              //   header: "Failed To Create Bucket",
              //   textHTML: errReason
              // });
            });
          });
        });
      }).error(function (errors) {
        reset();
        $scope.errors = errors;
      });
      return;
    }
  });