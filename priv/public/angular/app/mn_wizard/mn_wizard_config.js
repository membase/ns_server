angular.module('mnWizard').config(function ($stateProvider) {

  $stateProvider
    .state('wizard', {
      abstract: true,
      templateUrl: 'mn_wizard/mn_wizard.html',
      controller: 'mnWizardController',
      authenticate: false
    })
    .state('wizard.welcome', {
      templateUrl: 'mn_wizard/welcome/mn_wizard_welcome.html',
      controller: 'mnWizardWelcomeController',
      authenticate: false
    })
    .state('wizard.step1', {
      authenticate: false,
      views: {
        "": {
          templateUrl: 'mn_wizard/step1/mn_wizard_step1.html',
          controller: 'mnWizardStep1Controller',
        },
        "diskStorage@wizard.step1": {
          templateUrl: 'mn_wizard/step1/disk_storage/mn_wizard_step1_disk_storage.html',
          controller: 'mnWizardStep1DiskStorageController'
        },
        "joinCluster@wizard.step1": {
          templateUrl: 'mn_wizard/step1/join_cluster/mn_wizard_step1_join_cluster.html',
          controller: 'mnWizardStep1JoinClusterController'
        }
      }
    })
    .state('wizard.step2', {
      templateUrl: 'mn_wizard/step2/mn_wizard_step2.html',
      controller: 'mnWizardStep2Controller',
      authenticate: false
    })
    .state('wizard.step3', {
      templateUrl: 'mn_wizard/step3/mn_wizard_step3.html',
      controller: 'mnWizardStep3Controller',
      authenticate: false
    })
    .state('wizard.step4', {
      templateUrl: 'mn_wizard/step4/mn_wizard_step4.html',
      controller: 'mnWizardStep4Controller',
      authenticate: false
    })
    .state('wizard.step5', {
      templateUrl: 'mn_wizard/step5/mn_wizard_step5.html',
      controller: 'mnWizardStep5Controller',
      authenticate: false
    });
});