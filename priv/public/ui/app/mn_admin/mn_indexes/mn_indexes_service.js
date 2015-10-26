angular.module('mnIndexesService', [
  'mnHttp',
]).factory('mnIndexesService',
  function (mnHttp) {
    var mnIndexesService = {};

    mnIndexesService.getIndexesState = function () {
      return mnHttp({
        method: 'GET',
        url: '/indexStatus'
      }).then(function (resp) {
        return resp.data;
      });
    };

    return mnIndexesService;
  });
