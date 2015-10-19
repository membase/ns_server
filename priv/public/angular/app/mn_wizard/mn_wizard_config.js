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
  'mnPromiseHelper'
]).config(function ($stateProvider) {

  $stateProvider
    .state('app.wizard', {
      abstract: true,
      templateUrl: 'mn_wizard/mn_wizard.html'
    })
    .state('app.wizard.welcome', {
      templateUrl: 'mn_wizard/welcome/mn_wizard_welcome.html'
    })
    .state('app.wizard.step1', {
      templateUrl: 'mn_wizard/step1/mn_wizard_step1.html',
      controller: 'mnWizardStep1Controller'
    })
    .state('app.wizard.step2', {
      templateUrl: 'mn_wizard/step2/mn_wizard_step2.html',
      controller: 'mnWizardStep2Controller'
    })
    .state('app.wizard.step3', {
      templateUrl: 'mn_wizard/step3/mn_wizard_step3.html',
      controller: 'mnWizardStep3Controller'
    })
    .state('app.wizard.step4', {
      templateUrl: 'mn_wizard/step4/mn_wizard_step4.html',
      controller: 'mnWizardStep4Controller'
    })
    .state('app.wizard.step5', {
      templateUrl: 'mn_wizard/step5/mn_wizard_step5.html',
      controller: 'mnWizardStep5Controller'
    })
    .state('app.wizard.step6', {
      templateUrl: 'mn_wizard/step6/mn_wizard_step6.html',
      controller: 'mnWizardStep6Controller',
      resolve: {
        memoryQuotaConfig: function (mnMemoryQuotaService, mnWizardStep1Service) {
          return mnMemoryQuotaService.memoryQuotaConfig(mnWizardStep1Service.getJoinClusterConfig().services.model.kv);
        }
      }
    });
});