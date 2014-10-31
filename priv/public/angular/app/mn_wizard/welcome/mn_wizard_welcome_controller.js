angular.module('mnWizard').controller('mnWizardWelcomeController',
  function ($scope, pools) {
    $scope.implementationVersion = pools.implementationVersion;
    $scope.showAboutDialog = function () {
      mnDialogService.open({
        template: '/angular/app/mn_dialogs/about/mn_dialogs_about.html',
        scope: $scope
      });
    };
  });