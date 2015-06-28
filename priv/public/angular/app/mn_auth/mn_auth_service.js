angular.module('mnAuthService', [
  'mnHttp',
  'mnPools',
  'ui.router'
]).factory('mnAuthService',
  function (mnHttp, $rootScope, $state, mnPools) {

  var mnAuthService = {};

  mnAuthService.login = function (user) {
    user = user || {};
    return mnHttp({
      method: 'POST',
      url: '/uilogin',
      data: {
        user: user.username,
        password: user.password
      }
    }).then(function () {
      return mnPools.getFresh().then(function () {
        $state.go('app.admin.overview');
      });
    });
  };

  mnAuthService.logout = function () {
    return mnHttp({
      method: 'POST',
      url: "/uilogout"
    }).then(function () {
      return mnPools.getFresh().then(function () {
        $state.go('app.auth');
      });
    });
  };

  return mnAuthService;
});


