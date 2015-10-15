angular.module('mnPoll', [
  'mnTasksDetails',
  'mnPendingQueryKeeper'
]).factory('mnPoll',
  function ($timeout, $q, $rootScope, $state, mnTasksDetails, mnPendingQueryKeeper) {
    var stateKeeper = {};

    function poll(request, extractInterval, scope) {
      var deferred = $q.defer();
      var latestResult;
      var isCanceled;
      var timeout;
      var subscribers = [];
      var cancelOnScopeDestroy = false;
      var stateChangeStartBind;

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
            cancelOnScopeDestroy && mnPendingQueryKeeper.attachPendingQueriesToScope(scope);
          } else {
            timeout = $timeout(cycle, extractInterval);
            call();
            cancelOnScopeDestroy && mnPendingQueryKeeper.attachPendingQueriesToScope(scope);
          }
        } else {
          mnTasksDetails.getFresh().then(function (result) {
            if (isCanceled) {
              return;
            }
            var interval = (_.chain(result.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
            timeout = $timeout(cycle, interval);
            call();
            cancelOnScopeDestroy && mnPendingQueryKeeper.attachPendingQueriesToScope(scope);
          });
          cancelOnScopeDestroy && mnPendingQueryKeeper.attachPendingQueriesToScope(scope);
        }
      }

      function subscribe(subscriber, keeper) {
        deferred.promise.then(null, null, angular.isFunction(subscriber) ? subscriber : function (value) {
          (keeper || scope)[subscriber] = value;
        });
      }

      return {
        run: function () {
          cycle();
          return this;
        },
        cancelOnScopeDestroy: function () {
          cancelOnScopeDestroy = true;
          return this;
        },
        promise: function () {
          return deferred.promise;
        },
        stop: function () {
          stateChangeStartBind && stateChangeStartBind();
          isCanceled = true;
          $timeout.cancel(timeout);
        },
        subscribe: function (subscriber, keeper) {
          this.subscriber = subscriber;
          subscribe(subscriber, keeper);
          return this;
        },
        keepIn: function (key, keeper) {
          if (stateKeeper[key]) {
            if (angular.isFunction(this.subscriber)) {
              this.subscriber(stateKeeper[key]);
            } else {
              (keeper || scope)[this.subscriber] = stateKeeper[key];
            }
          }

          stateChangeStartBind = $rootScope.$on('$stateChangeStart', function (event, toState) {
            if (!(toState.name.indexOf(key) > -1)) {
              delete stateKeeper[key];
            }
          });

          subscribe(key, stateKeeper);
          return this;
        }
      };
    }

    return {
      start: function (scope, request, extractInterval) {
        var poller = poll(request, extractInterval, scope);
        scope.$on('$destroy', poller.stop);
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