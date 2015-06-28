angular.module('mnSettingsAutoFailoverService', [
  'mnHttp'
]).factory('mnSettingsAutoFailoverService',
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

    mnSettingsAutoFailoverService.saveAutoFailoverSettings = function (autoFailoverSettings) {
      return mnHttp({
        method: 'POST',
        url: "/settings/autoFailover",
        data: autoFailoverSettings
      });
    };

    return mnSettingsAutoFailoverService;
});