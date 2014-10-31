angular.module('mnAdminSettingsAutoFailoverService').factory('mnAdminSettingsAutoFailoverService',
  function (mnHttp) {
    var mnAdminSettingsAutoFailoverService = {};

    mnAdminSettingsAutoFailoverService.resetAutoFailOverCount = function () {
      return mnHttp({
        method: 'POST',
        url: '/settings/autoFailover/resetCount',
      });
    };

    mnAdminSettingsAutoFailoverService.getAutoFailoverSettings = function () {
      return mnHttp({
        method: 'GET',
        url: "/settings/autoFailover"
      });
    };

    return mnAdminSettingsAutoFailoverService;
});