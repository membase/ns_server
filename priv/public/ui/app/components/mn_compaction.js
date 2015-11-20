(function () {
  "use strict";

  angular.module('mnCompaction', [
    'mnHttp'
  ]).factory('mnCompaction', mnCompactionFactory);

  function mnCompactionFactory($interval, mnHttp) {
    var startedCompactions = {};
    var mnCompaction = {
      registerAsTriggered: registerAsTriggered,
      registerAsTriggeredAndPost: registerAsTriggeredAndPost,
      getStartedCompactions: getStartedCompactions,
      canCompact: canCompact
    };

    activate();

    return mnCompaction;

    function activate() {
      $interval(function () {
        _.each(startedCompactions, mayBeExpired);
      }, 2000);
    }
    function now() {
      return new Date().valueOf();
    }
    function mayBeExpired(desc, key) {
      if (desc.staredAt < now()) {
        desc.undoBody();
        delete startedCompactions[key];
      }
    }
    function registerAsTriggered(url, undoBody) {
      if (startedCompactions[url]) {
        mayBeExpired(startedCompactions[url], url);
      } else {
        startedCompactions[url] = {
          url: url,
          undoBody: undoBody || new Function(),
          staredAt: now() + 10000
        };
      }
    }
    function registerAsTriggeredAndPost(url, undoBody) {
      mnCompaction.registerAsTriggered(url, undoBody);
      return mnHttp.post(url);
    }
    function getStartedCompactions() {
      return startedCompactions;
    }
    function canCompact(url) {
      var desc = startedCompactions[url];
      return desc ? desc.staredAt <= now() : true;
    }
  }
})();
