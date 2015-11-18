(function () {
  "use strict";

  angular.module('mnSettingsAutoFailoverService', [
    'mnHttp'
  ]).factory('mnSettingsAutoFailoverService', mnSettingsAutoFailoverServiceFactory);

  function mnSettingsAutoFailoverServiceFactory(mnHttp) {
    var mnSettingsAutoFailoverService = {
      resetAutoFailOverCount: resetAutoFailOverCount,
      getAutoFailoverSettings: getAutoFailoverSettings,
      saveAutoFailoverSettings: saveAutoFailoverSettings
    };

    return mnSettingsAutoFailoverService;

    function resetAutoFailOverCount() {
      return mnHttp({
        method: 'POST',
        url: '/settings/autoFailover/resetCount'
      });
    }
    function getAutoFailoverSettings() {
      return mnHttp({
        method: 'GET',
        url: "/settings/autoFailover"
      });
    }
    function saveAutoFailoverSettings(autoFailoverSettings) {
      return mnHttp({
        method: 'POST',
        url: "/settings/autoFailover",
        data: autoFailoverSettings
      });
    }
  }
})();
