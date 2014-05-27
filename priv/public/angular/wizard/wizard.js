angular.module('wizard', [
  'wizard.step1.service',
  'wizard.step1.diskStorage.service',
  'wizard.step1.joinCluster.service',
  'wizard.step2.service',
  'wizard.step3.service',
  'wizard.step4.service',
  'wizard.step5.service',
  'ui.router'
]).config(['$stateProvider', '$urlRouterProvider',
    function ($stateProvider, $urlRouterProvider) {

      $stateProvider
        .state('wizard', {
          abstract: true,
          templateUrl: '/angular/wizard/wizard.html',
          controller: 'wizard.Controller',
          authenticate: false
        })
        .state('wizard.welcome', {
          templateUrl: '/angular/wizard/welcome/welcome.html',
          controller: 'wizard.welcome.Controller',
          authenticate: false
        })
        .state('wizard.step1', {
          abstract: true,
          templateUrl: '/angular/wizard/step1/step1.html',
          controller: 'wizard.step1.Controller',
          authenticate: false
        })
        .state('wizard.step1.views', {
          views: {
            diskStorage: {
              templateUrl: '/angular/wizard/step1/disk_storage/step1_disk_storage.html',
              controller: 'wizard.step1.diskStorage.Controller'
            },
            joinCluster: {
              templateUrl: '/angular/wizard/step1/join_cluster/step1_join_cluster.html',
              controller: 'wizard.step1.joinCluster.Controller'
            }
          }
        })
        .state('wizard.step2', {
          templateUrl: '/angular/wizard/step2/step2.html',
          controller: 'wizard.step2.Controller',
          authenticate: false
        })
        .state('wizard.step3', {
          templateUrl: '/angular/wizard/step3/step3.html',
          controller: 'wizard.step3.Controller',
          authenticate: false
        })
        .state('wizard.step4', {
          templateUrl: '/angular/wizard/step4/step4.html',
          controller: 'wizard.step4.Controller',
          authenticate: false
        })
        .state('wizard.step5', {
          templateUrl: '/angular/wizard/step5/step5.html',
          controller: 'wizard.step5.Controller',
          authenticate: false
        });
    }]);