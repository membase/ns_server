(function () {
  "use strict";

  angular.module("mnPoll", [
    "mnPollClasses"
  ]).factory("mnPoll", mnPollFactory);

  function mnPollFactory(MnPollClass, MnEtagBasedPollClass, $cacheFactory) {

    var mnPoll = {
      start: start,
      startEtagBased: startEtagBased,
      cleanCache: cleanCache
    };

    return mnPoll;

    function startEtagBased(scope, request) {
      var poller = new MnEtagBasedPollClass(request, scope);
      scope.$on('$destroy', poller.stop.bind(poller));
      return poller;
    }
    function start(scope, request, extractInterval) {
      var poller = new MnPollClass(request, scope, extractInterval);
      scope.$on('$destroy', poller.stop.bind(poller));
      return poller;
    }
    function cleanCache(key) {
      $cacheFactory.get("stateKeeper").remove(key);
    }
  }
})();
