angular.module('mnWizard').config(function ($stateProvider) {

  $stateProvider
    .state('app.wizard', {
      abstract: true,
      templateUrl: 'mn_wizard/mn_wizard.html',
      notAuthenticate: true
    })
    .state('app.wizard.welcome', {
      templateUrl: 'mn_wizard/welcome/mn_wizard_welcome.html',
      notAuthenticate: true
    })
    .state('app.wizard.step1', {
      notAuthenticate: true,
      templateUrl: 'mn_wizard/step1/mn_wizard_step1.html',
      controller: 'mnWizardStep1Controller',
      resolve: {
        selfConfig: function (mnWizardStep1Service) {
          return mnWizardStep1Service.getSelfConfig();
        }
      }
    })
    .state('app.wizard.step2', {
      templateUrl: 'mn_wizard/step2/mn_wizard_step2.html',
      controller: 'mnWizardStep2Controller',
      notAuthenticate: true,
      resolve: {
        sampleBuckets: function (mnWizardStep2Service) {
          return mnWizardStep2Service.getSampleBuckets();
        }
      }
    })
    .state('app.wizard.step3', {
      templateUrl: 'mn_wizard/step3/mn_wizard_step3.html',
      controller: 'mnWizardStep3Controller',
      notAuthenticate: true,
      resolve: {
        bucketConf: function (mnWizardStep3Service) {
          return mnWizardStep3Service.getBucketConf();
        }
      }
    })
    .state('app.wizard.step4', {
      templateUrl: 'mn_wizard/step4/mn_wizard_step4.html',
      controller: 'mnWizardStep4Controller',
      notAuthenticate: true
    })
    .state('app.wizard.step5', {
      templateUrl: 'mn_wizard/step5/mn_wizard_step5.html',
      controller: 'mnWizardStep5Controller',
      notAuthenticate: true
    });
});