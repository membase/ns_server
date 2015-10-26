angular.module('mnLogsService', [
  'mnHttp',
  'mnLogsCollectInfoService'
]).service('mnLogsService',
  function (mnHttp) {
    var mnLogsService = {};

    mnLogsService.getLogs = function () {
      return mnHttp.get('/logs');
    };

    return mnLogsService;
  });