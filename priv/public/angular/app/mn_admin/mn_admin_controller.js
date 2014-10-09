angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, $state, $location, mnAuthService, mnAdminService, mnAdminServersService, mnAdminTasksService) {
    $scope.$state = $state;
    $scope.$location = $location;
    $scope._ = _;
    $scope.Math = Math;
    $scope.logout = mnAuthService.manualLogout;

    $scope.mnAdminServiceModel = mnAdminService.model;
    $scope.mnAdminServersServiceModel = mnAdminServersService.model;
    $scope.mnAdminTasksServiceModel = mnAdminTasksService.model;

    mnAdminService.initializeWatchers($scope);

  });