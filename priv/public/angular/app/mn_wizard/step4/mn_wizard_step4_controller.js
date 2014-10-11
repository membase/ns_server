angular.module('mnWizard').controller('mnWizardStep4Controller',
  function ($scope, $state, mnWizardStep4Service, mnAuthService) {

    mnWizardStep4Service.model.register.version = mnAuthService.model.version || 'unknown';
    $scope.mnWizardStep4ServiceModel = mnWizardStep4Service.model;

    function viewLoadingCtrl(state) {
      $scope.viewLoading = state;
    }

    $scope.onSubmit = function () {
      if ($scope.form.$invalid || $scope.viewLoading) {
        return;
      }

      if ($scope.mnWizardStep4ServiceModel.register.email) {
        var data = _.clone(mnWizardStep4Service.model.register);
        delete data.agree;
        mnWizardStep4Service.postEmail({params: data});
      }

      mnWizardStep4Service.postStats({
        spinner: viewLoadingCtrl,
        data: {
          sendStats: mnWizardStep4Service.model.sendStats
        }
      }).success(function () {
        $state.go('wizard.step5');
      }).error(function (errors) {
        $scope.errors = errors;
      });
    };
  });