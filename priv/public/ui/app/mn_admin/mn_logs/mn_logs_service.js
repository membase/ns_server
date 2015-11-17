(function () {
  "use strict";

  angular.module('mnLogsService', [
    'mnHttp',
    'mnLogsCollectInfoService'
  ]).service('mnLogsService', mnLogsServiceFactory);

  function mnLogsServiceFactory(mnHttp) {
    var mnLogsService = {
      getLogs: getLogs
    };

    return mnLogsService;

    function getLogs() {
      return mnHttp.get('/logs');
    }
  }
})();
