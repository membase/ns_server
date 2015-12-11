(function () {
  "use strict";

  angular
    .module("mnPendingQueryKeeper", [])
    .factory("mnPendingQueryKeeper", mnPendingQueryKeeperFactory);

  function mnPendingQueryKeeperFactory() {
    var pendingQueryKeeper = [];

    return {
      getQueryInFly: getQueryInFly,
      removeQueryInFly: removeQueryInFly,
      push: push,
      cancelTabsSpecificQueries: cancelTabsSpecificQueries,
      cancelAllQueries: cancelAllQueries
    };

    function cancelAllQueries() {
      angular.forEach(pendingQueryKeeper, function (query) {
        query.canceler();
      });
    }
    function cancelTabsSpecificQueries() {
      angular.forEach(pendingQueryKeeper, function (query) {
        if (query.group !== "global") {
          query.canceler();
        }
      });
    }

    function removeQueryInFly(findMe) {
      _.remove(pendingQueryKeeper, function (pendingQuery) {
        return pendingQuery === findMe;
      });
    }

    function getQueryInFly(config) {
      return _.find(pendingQueryKeeper, function (inFly) {
        return inFly.config.method === config.method &&
               inFly.config.url === config.url;
      });
    }

    function push(query) {
      pendingQueryKeeper.push(query);
    }
  }
})();
