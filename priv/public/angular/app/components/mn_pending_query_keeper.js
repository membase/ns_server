(function () {
  "use strict";

  angular
    .module("mnPendingQueryKeeper", [])
    .factory("mnPendingQueryKeeper", mnPendingQueryKeeperFactory);

  function mnPendingQueryKeeperFactory() {
    var pendingQueryKeeper = [];

    return {
      attachPendingQueriesToScope: attachPendingQueriesToScope,
      markAsIndependentOfScope: markAsIndependentOfScope,
      getQueryInFly: getQueryInFly,
      removeQueryInFly: removeQueryInFly,
      push: push
    };;

    function attachPendingQueriesToScope($scope) {
      var queries = getQueriesOfRecentPromise();
      _.forEach(queries, function (query) {
        query.isAttachedToScope = true;
        $scope.$on("$destroy", query.canceler);
      });
    }

    function markAsIndependentOfScope() {
      var queries = getQueriesOfRecentPromise();
      _.forEach(queries, function (query) {
        query.doesNotBelongToScope = true;
      });
    }

    function getQueriesOfRecentPromise() {
      return _.takeRightWhile(pendingQueryKeeper, function (query) {
        return !query.isAttachedToScope && !query.doesNotBelongToScope;
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
