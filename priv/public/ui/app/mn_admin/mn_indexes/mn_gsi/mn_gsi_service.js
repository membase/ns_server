(function () {
  "use strict";

  angular.module('mnGsiService', [
  ]).factory('mnGsiService', mnGsiServiceFactory);

  function mnGsiServiceFactory($http) {
    var mnGsiService = {
      getIndexesState: getIndexesState
    };

    return mnGsiService;

    function getIndexesState(mnHttpParams) {
      return $http({
        method: 'GET',
        url: '/indexStatus',
        mnHttp: mnHttpParams
      }).then(function (resp) {
        resp.data.groups = _.groupBy(resp.data.indexes, 'bucket');
        resp.data.nodes = _.groupBy(resp.data.indexes, function (index) {
          return index.hosts.join(", ");
        });
        return resp.data;
      });
    }
  }
})();
