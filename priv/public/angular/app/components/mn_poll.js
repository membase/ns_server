angular.module('mnPoll', [
  'mnTasksDetails',
  'mnHttp'
]).factory('mnPoll',
  function ($timeout, $q, mnTasksDetails) {
    var stateKeeper = {};

    function poll(request, extractInterval, scope) {
      var deferred;
      var latestResult;
      var isCanceled;
      var timeout;
      var subscribers = [];

      function call() {
        var query = angular.isFunction(request) ? request(latestResult) : request;
        query.then(function (result) {
          if (isCanceled) {
            return;
          }
          latestResult = result;
          deferred.notify(latestResult);
        });
        return query;
      }

      function cycle() {
        if (extractInterval) {
          if (angular.isFunction(extractInterval)) {
            call().then(function (result) {
              if (isCanceled) {
                return;
              }
              var interval = extractInterval(result);
              timeout = $timeout(cycle, interval);
            });
          } else {
            timeout = $timeout(cycle, extractInterval);
            call();
          }
        } else {
          mnTasksDetails.getFresh().then(function (result) {
            if (isCanceled) {
              return;
            }
            var interval = (_.chain(result.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
            timeout = $timeout(cycle, interval);
            call();
          });
        }
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
          isCanceled = true;
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