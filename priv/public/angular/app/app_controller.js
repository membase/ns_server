angular.module('app')
  .controller('app.Controller',
    ['$scope', '$state', '$location', 'auth.service', 'app.service',
      function ($scope, $state, $location, authService, appService) {
        $scope.$state = $state;
        $scope.$location = $location;
        $scope._ = _;
        $scope.Math = Math;
        $scope.logout = authService.manualLogout;

        $scope.$watch(function () {
          if (!(authService.model.defaultPoolUri && authService.model.isAuth)) {
            return;
          }

          return {
            url: authService.model.defaultPoolUri,
            params: {
              waitChange: $state.current.name === 'app.overview' ||
                          $state.current.name === 'app.manage_servers' ?
                          3000 : 20000
            }
          };
        }, appService.runDefaultPoolsDetailsLoop, true);
      }]);