(function () {
  "use strict";

  angular.module('mnIndexesService', [
    'mnHttp',
  ]).factory('mnIndexesService', mnIndexesServiceFactory);

  function mnIndexesServiceFactory(mnHttp) {
    var mnIndexesService = {
      getIndexesState: getIndexesState
    };

    return mnIndexesService;

    function getIndexesState() {
      return mnHttp({
        method: 'GET',
        url: '/indexStatus'
      }).then(function (resp) {
        return resp.data;
      });
    }
  }
})();
