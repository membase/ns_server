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

      function subscribe(subscriber, keeper) {
        subscribers.push(arguments);
        doSubscribe(subscriber, keeper);
      }

      function doSubscribe(subscriber, keeper) {
        deferred.promise.then(null, null, angular.isFunction(subscriber) ? subscriber : function (value) {
          (keeper || scope)[subscriber] = value;
        });
      }

      function reSubscribe() {
        _.each(subscribers, function (args) {
          doSubscribe.apply(this, args);
        });
        subscribers = [];
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
        restart: function () {
          this.stop();
          this.start();
          reSubscribe();
        },
        subscribe: function (subscriber) {
          this.subscriber = subscriber;
          subscribe(subscriber);
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

          subscribe(key, stateKeeper);
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