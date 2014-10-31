angular.module('mnAuthService').factory('mnAuthService',
  function ($rootScope, mnHttp, $state, $urlRouter, mnAdminService) {

  var mnAuthService = {};

  mnAuthService.getPools = function () {
    return mnHttp({
      method: 'GET',
      url: '/pools',
      requestType: 'json'
    }).then(function (resp) {
      var pools = resp.data;
      var rv = {};
      pools.isInitialized = !!pools.pools.length;
      pools.isAuthenticated = pools.isAdminCreds && pools.isInitialized;
      return pools;
    }, function (resp) {
      if (resp.status === 401) {
        return {isInitialized: true, isAuthenticated: false};
      }
    });
  };


  mnAuthService.manualLogin = function (user) {
    user = user || {};
    return mnHttp({
      method: 'POST',
      url: '/uilogin',
      data: {
        user: user.username,
        password: user.password
      }
    });
  };

  mnAuthService.manualLogout = function () {
    return mnHttp({
      method: 'POST',
      url: "/uilogout"
    });
  };

  return mnAuthService;
});


