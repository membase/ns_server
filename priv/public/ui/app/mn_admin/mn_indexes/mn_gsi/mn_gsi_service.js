(function () {
  "use strict";

  angular.module('mnGsiService', [
    'mnHttp',
  ]).factory('mnGsiService', mnGsiServiceFactory);

  function mnGsiServiceFactory(mnHttp) {
    var mnGsiService = {
      getIndexesState: getIndexesState
    };

    return mnGsiService;

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
