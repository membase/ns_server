angular.module('mnPoll', [
  'mnTasksDetails'
]).factory('mnPoll',
  function ($timeout, $q, mnTasksDetails) {
    var stateKeeper = {};

    function poll(request, extractInterval, scope) {
      var deferred;
      var latestResult;
      var stopTimestamp;
      var timeout;
      var subscribers = [];

      function cycle() {
        var timestamp = new Date();
        var queries = [angular.isFunction(request) ? request(latestResult) : request];
        if (!extractInterval) {
          queries.push(mnTasksDetails.get());
        }
        function isNotOutstanding() {
          return !stopTimestamp || timestamp >= stopTimestamp;
        }
        $q.all(queries).then(function (result) {
          if (isNotOutstanding()) {
            latestResult = result[0];
            var interval;
            if (!extractInterval) {
              interval = (_.chain(result[1].tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
            } else {
              interval = angular.isFunction(extractInterval) ? extractInterval(latestResult) : extractInterval;
            }
            deferred.notify(latestResult);
            timeout = $timeout(cycle, interval);
          }
        });
      }

      return {
        start: function () {
          deferred = $q.defer();
          cycle();
        },
        promise: function () {
          return deferred.promise;
        },
        stop: function () {
          stopTimestamp = new Date();
          $timeout.cancel(timeout);
        },
        subscribe: function (subscriber, keeper) {
          this.subscriber = subscriber;
          deferred.promise.then(null, null, angular.isFunction(subscriber) ? subscriber : function (value) {
            (keeper || scope)[subscriber] = value;
          });
          return this;
        },
        keepIn: function (key) {
          if (angular.isFunction(this.subscriber) && !angular.isString(key)) {
            throw new Error("argument \"key\" must have type string");
          }
          key = key || this.subscriber;
          if (stateKeeper[key]) {
            if (angular.isFunction(this.subscriber)) {
              this.subscriber(stateKeeper[key]);
            } else {
              scope[key] = stateKeeper[key];
            }
          }

          this.subscribe(key, stateKeeper);
          return this;
        }
      };
    }

    return {
      start: function (scope, request, extractInterval) {
        var poller = poll(request, extractInterval, scope);
        scope.$on('$destroy', poller.stop);
        poller.start();
        return poller;
      },
      cleanCache: function (key) {
        if (key) {
          delete stateKeeper[key];
        } else {
          stateKeeper = {};
        }
      }
    };
  });