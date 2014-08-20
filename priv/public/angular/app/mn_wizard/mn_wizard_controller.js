angular.module('mnWizard').controller('mnWizardController',
  function ($scope, mnAuthService) {
    $scope.mnAuthServiceModel = mnAuthService.model;
  });