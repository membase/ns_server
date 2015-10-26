angular.module('mnCompaction', [
  'mnHttp'
]).factory('mnCompaction',
  function ($interval, mnHttp) {
    var mnCompaction = {};
    var startedCompactions = {};

    $interval(function () {
      _.each(startedCompactions, mayBeExpired);
    }, 2000);

    function now() {
      return new Date().valueOf();
    }

    function mayBeExpired(desc, key) {
      if (desc.staredAt < now()) {
        desc.undoBody();
        delete startedCompactions[key];
      }
    }

    mnCompaction.registerAsTriggered = function (url, undoBody) {
      if (startedCompactions[url]) {
        mayBeExpired(startedCompactions[url], url);
      } else {
        startedCompactions[url] = {
          url: url,
          undoBody: undoBody || new Function(),
          staredAt: now() + 10000
        };
      }
    };

    mnCompaction.registerAsTriggeredAndPost = function (url, undoBody) {
      mnCompaction.registerAsTriggered(url, undoBody);
      return mnHttp.post(url);
    };

    mnCompaction.getStartedCompactions = function () {
      return startedCompactions;
    };

    mnCompaction.canCompact = function (url) {
      var desc = startedCompactions[url];
      return desc ? desc.staredAt <= now() : true;
    };

    return mnCompaction;
  });
