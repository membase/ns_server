(function () {
  "use strict";

  angular.module('mnWizard', [
    'mnAuthService',
    'mnServersService',
    'mnAlertsService',
    'mnHelper',
    'ui.router',
    'mnWizardStep1Service',
    'mnWizardStep2Service',
    'mnWizardStep3Service',
    'mnWizardStep4Service',
    'mnWizardStep5Service',
    'mnSettingsSampleBucketsService',
    'mnMemoryQuota',
    'mnPoolDefault',
    'mnMemoryQuotaService',
    'mnSettingsClusterService',
    'mnSpinner',
    'mnPromiseHelper',
    'mnFilters'
  ]).config(mnWizardConfig);

  function mnWizardConfig($stateProvider) {
    $stateProvider
      .state('app.wizard', {
        abstract: true,
        templateUrl: 'app/mn_wizard/mn_wizard.html',
        controller: "mnWizardWelcomeController as mnWizardWelcomeController"
      })
      .state('app.wizard.welcome', {
        templateUrl: 'app/mn_wizard/welcome/mn_wizard_welcome.html'
      })
      .state('app.wizard.step1', {
        templateUrl: 'app/mn_wizard/step1/mn_wizard_step1.html',
        controller: 'mnWizardStep1Controller as mnWizardStep1Controller'
      })
      .state('app.wizard.step2', {
        templateUrl: 'app/mn_wizard/step2/mn_wizard_step2.html',
        controller: 'mnWizardStep2Controller as mnWizardStep2Controller'
      })
      .state('app.wizard.step3', {
        templateUrl: 'app/mn_wizard/step3/mn_wizard_step3.html',
        controller: 'mnWizardStep3Controller as mnWizardStep3Controller'
      })
      .state('app.wizard.step4', {
        templateUrl: 'app/mn_wizard/step4/mn_wizard_step4.html',
        controller: 'mnWizardStep4Controller as mnWizardStep4Controller'
      })
      .state('app.wizard.step5', {
        templateUrl: 'app/mn_wizard/step5/mn_wizard_step5.html',
        controller: 'mnWizardStep5Controller as mnWizardStep5Controller'
      })
      .state('app.wizard.step6', {
        templateUrl: 'app/mn_wizard/step6/mn_wizard_step6.html',
        controller: 'mnWizardStep6Controller as mnWizardStep6Controller',
        resolve: {
          memoryQuotaConfig: function (mnMemoryQuotaService, mnWizardStep1Service) {
            return mnMemoryQuotaService.memoryQuotaConfig(mnWizardStep1Service.getJoinClusterConfig().services.model.kv);
          }
        }
      });
  }
})();
