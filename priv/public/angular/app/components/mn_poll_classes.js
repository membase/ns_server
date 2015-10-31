(function () {
  "use strict";

  angular
    .module("mnPollClasses", [
      "mnTasksDetails",
      "mnPendingQueryKeeper"
    ])
    .factory("MnPollClass", mnPollClass)
    .factory("MnEtagBasedPollClass", mnEtagBasedPollClass);

  function mnEtagBasedPollClass(MnPollClass, mnPendingQueryKeeper) {
    function EtagBasedPoll(request, scope) {
      MnPollClass.call(this, request, scope);
    }

    EtagBasedPoll.prototype = Object.create(MnPollClass.prototype);
    EtagBasedPoll.prototype.constructor = EtagBasedPoll;
    EtagBasedPoll.prototype.cycle = etagBasedCycle;

    return EtagBasedPoll;

    function etagBasedCycle() {
      var self = this;
      self.doCall().then(function () {
        if (self.isCanceled) {
          return;
        }
        self.cycle();
      });
      self.cancelOnScopeDestroyFlag && mnPendingQueryKeeper.attachPendingQueriesToScope(self.scope);
    }
  }

  function mnPollClass($q, $cacheFactory, $timeout, $rootScope, mnTasksDetails, mnPendingQueryKeeper) {
    $cacheFactory('stateKeeper');

    function Poll(request, scope, extractInterval) {
      this.deferred = $q.defer();
      this.cancelOnScopeDestroyFlag = false;
      this.request = request;
      this.extractInterval = extractInterval;
      this.scope = scope;

      this.latestResult = undefined;
      this.isCanceled = undefined;
      this.timeout = undefined;
      this.stateChangeStartBind = undefined;
    }

    Poll.prototype.doCall = doCall;
    Poll.prototype.cycle = cycle;
    Poll.prototype.stop = stop;
    Poll.prototype.subscribe = subscribe;
    Poll.prototype.doSubscribe = doSubscribe;
    Poll.prototype.cancelOnScopeDestroy = cancelOnScopeDestroy;
    Poll.prototype.keepIn = keepIn;

    return Poll;

    function doCall() {
      var self = this;
      var query = angular.isFunction(self.request) ? self.request(self.latestResult) : self.request;
      query.then(function (result) {
        if (self.isCanceled) {
          return;
        }
        self.deferred.notify(result);
      });
      return query;
    }
    function cycle() {
      var self = this;
      if (self.extractInterval) {
        if (angular.isFunction(self.extractInterval)) {
          self.doCall().then(function (result) {
            if (self.isCanceled) {
              return;
            }
            var interval = self.extractInterval(result);
            self.timeout = $timeout(self.cycle.bind(self), interval);
          });
          self.cancelOnScopeDestroyFlag && mnPendingQueryKeeper.attachPendingQueriesToScope(self.scope);
        } else {
          self.timeout = $timeout(self.cycle.bind(self), self.extractInterval);
          self.doCall();
          self.cancelOnScopeDestroyFlag && mnPendingQueryKeeper.attachPendingQueriesToScope(self.scope);
        }
      } else {
        mnTasksDetails.getFresh().then(function (result) {
          if (self.isCanceled) {
            return;
          }
          var interval = (_.chain(result.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
          self.timeout = $timeout(self.cycle.bind(self), interval);
          self.doCall();
          self.cancelOnScopeDestroyFlag && mnPendingQueryKeeper.attachPendingQueriesToScope(self.scope);
        });
        self.cancelOnScopeDestroyFlag && mnPendingQueryKeeper.attachPendingQueriesToScope(self.scope);
      }
    }
    function doSubscribe(subscriber, keeper) {
      var self = this;
      self.deferred.promise.then(null, null, angular.isFunction(subscriber) ? function (value) {
        subscriber(value, self.latestResult);
        self.latestResult = value;
      } : function (value) {
        if (keeper && keeper.put) {
          keeper.put(subscriber, [value, self.latestResult]);
        } else {
          (keeper || self.scope)[subscriber] = value;
        }
        self.latestResult = value;
      });
    }
    function cancelOnScopeDestroy() {
      this.cancelOnScopeDestroyFlag = true;
      return this;
    }
    function stop() {
      var self = this;
      self.stateChangeStartBind && this.stateChangeStartBind();
      self.isCanceled = true;
      $timeout.cancel(self.timeout);
    }
    function subscribe(subscriber, keeper) {
      this.subscriber = subscriber;
      this.doSubscribe(subscriber, keeper);
      return this;
    }
    function keepIn(key, keeper) {
      var self = this;
      var stateKeeper = $cacheFactory.get("stateKeeper");
      if (stateKeeper.get(key)) {
        if (angular.isFunction(self.subscriber)) {
          self.subscriber(stateKeeper.get(key)[0], stateKeeper.get(key)[1]);
        } else {
          (keeper || self.scope)[self.subscriber] = stateKeeper.get(key)[0];
        }
      }

      self.stateChangeStartBind = $rootScope.$on('$stateChangeStart', function (event, toState) {
        if (!(toState.name.indexOf(key) > -1)) {
          stateKeeper.remove(key);
        }
      });

      self.doSubscribe(key, stateKeeper);
      return self;
    }
  }
})();
