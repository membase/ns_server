angular.module('mnAdminSettingsAutoFailoverService').factory('mnAdminSettingsAutoFailoverService',
  function ($http, $q) {
    var mnAdminSettingsAutoFailoverService = {};

    var resetAutoFailOverCountCanceler;
    mnAdminSettingsAutoFailoverService.resetAutoFailOverCount = function () {
      resetAutoFailOverCountCanceler && resetAutoFailOverCountCanceler.resolve();
      resetAutoFailOverCountCanceler = $q.defer();

      return $http({
        method: 'POST',
        url: '/settings/autoFailover/resetCount',
        timeout: resetAutoFailOverCountCanceler.promise
      });
    };

    mnAdminSettingsAutoFailoverService.getAutoFailoverSettings = function (url) {
      return $http({method: 'GET', url: "/settings/autoFailover"});
    };

    return mnAdminSettingsAutoFailoverService;
});