angular.module('mnAdmin').controller('mnAdminController',
  function ($scope, $state, $location, mnAuthService, mnAdminService, mnAdminServersService) {
    $scope.$state = $state;
    $scope.$location = $location;
    $scope._ = _;
    $scope.Math = Math;
    $scope.logout = mnAuthService.manualLogout;

    //app model sharing
    $scope.mnAdminServiceModel = mnAdminService.model;
    $scope.mnAdminServersServiceModel = mnAdminServersService.model;

    $scope.$watch('mnAdminServiceModel.details.nodes', mnAdminServersService.populateModel);

    $scope.$watch(function () {
      if (!(mnAuthService.model.defaultPoolUri && mnAuthService.model.isAuth)) {
        return;
      }

      return {
        url: mnAuthService.model.defaultPoolUri,
        params: {
          waitChange: $state.current.name === 'app.overview' ||
                      $state.current.name === 'app.manage_servers' ?
                      3000 : 20000
        }
      };
    }, mnAdminService.runDefaultPoolsDetailsLoop, true);
  });