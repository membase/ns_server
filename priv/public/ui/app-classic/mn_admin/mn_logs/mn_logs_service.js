(function () {
  "use strict";

  angular.module('mnLogsService', [
    'mnLogsCollectInfoService'
  ]).service('mnLogsService', mnLogsServiceFactory);

  function mnLogsServiceFactory($http) {
    var mnLogsService = {
      getLogs: getLogs
    };

    return mnLogsService;

    function getLogs() {
      return $http.get('/logs');
    }
  }
})();
