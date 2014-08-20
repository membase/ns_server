angular.module('mnWizard').controller('mnWizardStep4Controller',
  function ($scope, $state, mnWizardStep4Service, mnAuthService) {

    mnWizardStep4Service.model.register.version = mnAuthService.model.version || 'unknown';
    $scope.mnWizardStep4ServiceModel = mnWizardStep4Service.model;

    $scope.onSubmit = function () {
      if ($scope.form.$invalid || $scope.viewLoading) {
        return;
      }
      $scope.viewLoading = true;

      $scope.mnWizardStep4ServiceModel.register.email && mnWizardStep4Service.postEmail();

      mnWizardStep4Service.postStats().success(function () {
        $scope.viewLoading = false;
        $state.transitionTo('wizard.step5');
      }).error(function (errors) {
        $scope.viewLoading = false;
        $scope.errors = errors;
      });
    };
  });