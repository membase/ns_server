(function () {
  "use strict";

  angular.module('mnGsiService', [
  ]).factory('mnGsiService', mnGsiServiceFactory);

  function mnGsiServiceFactory($http) {
    var mnGsiService = {
      getIndexesState: getIndexesState
    };

    return mnGsiService;

    function getIndexesState() {
      return $http({
        method: 'GET',
        url: '/indexStatus'
      }).then(function (resp) {
        return resp.data;
      });
    }
  }
})();
