(function () {
  "use strict";

  angular.module('mnSettingsAutoFailoverService', [
  ]).factory('mnSettingsAutoFailoverService', mnSettingsAutoFailoverServiceFactory);

  function mnSettingsAutoFailoverServiceFactory($http) {
    var mnSettingsAutoFailoverService = {
      resetAutoFailOverCount: resetAutoFailOverCount,
      getAutoFailoverSettings: getAutoFailoverSettings,
      saveAutoFailoverSettings: saveAutoFailoverSettings
    };

    return mnSettingsAutoFailoverService;

    function resetAutoFailOverCount(mnHttpParams) {
      return $http({
        method: 'POST',
        url: '/settings/autoFailover/resetCount',
        mnHttp: mnHttpParams
      });
    }
    function getAutoFailoverSettings() {
      return $http({
        method: 'GET',
        url: "/settings/autoFailover"
      });
    }
    function saveAutoFailoverSettings(autoFailoverSettings) {
      return $http({
        method: 'POST',
        url: "/settings/autoFailover",
        data: autoFailoverSettings
      });
    }
  }
})();
