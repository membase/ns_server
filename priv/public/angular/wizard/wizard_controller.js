angular.module('wizard')
  .controller('wizard.Controller',
    ['$scope', '$state', '$location', 'auth.service',
      function ($scope, $state, $location, authService) {
        $scope.modelAuthService = authService.model;
      }]);