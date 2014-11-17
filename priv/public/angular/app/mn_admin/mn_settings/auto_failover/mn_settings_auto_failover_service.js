angular.module('mnSettingsAutoFailoverService').factory('mnSettingsAutoFailoverService',
  function (mnHttp) {
    var mnSettingsAutoFailoverService = {};

    mnSettingsAutoFailoverService.resetAutoFailOverCount = function () {
      return mnHttp({
        method: 'POST',
        url: '/settings/autoFailover/resetCount'
      });
    };

    mnSettingsAutoFailoverService.getAutoFailoverSettings = function () {
      return mnHttp({
        method: 'GET',
        url: "/settings/autoFailover"
      });
    };

    return mnSettingsAutoFailoverService;
});