angular.module('mnWizard').controller('mnWizardWelcomeController',
  function ($scope, mnDialogService) {
    $scope.showAboutDialog = function () {
      mnDialogService.open({
        template: '/angular/app/mn_dialogs/about/mn_dialogs_about.html',
        scope: $scope
      });
    };
  });