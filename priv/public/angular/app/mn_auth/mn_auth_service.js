angular.module('mnAuthService').factory('mnAuthService',
  function (mnHttp) {

  var mnAuthService = {};

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


