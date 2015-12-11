(function () {
  "use strict";

  angular
    .module("mnPoll", [
      "mnTasksDetails",
      "mnPendingQueryKeeper",
      "mnPromiseHelper"
    ])
    .factory("mnPoller", mnPollerFactory)
    .factory("mnEtagPoller", mnEtagPollerFactory);

  function mnEtagPollerFactory(mnPoller, mnPendingQueryKeeper) {
    function EtagPoller(scope, request) {
      mnPoller.call(this, scope, request);
    }

    EtagPoller.prototype = Object.create(mnPoller.prototype);
    EtagPoller.prototype.constructor = EtagPoller;
    EtagPoller.prototype.cycle = cycle;

    return EtagPoller;

    function cycle() {
      var self = this;
      self.doCall().then(function () {
        if (self.isCanceled) {
          return;
        }
        self.cycle();
      });
    }
  }

  function mnPollerFactory($q, $cacheFactory, $timeout, $rootScope, mnTasksDetails, mnPendingQueryKeeper, mnPromiseHelper) {
    $cacheFactory('stateKeeper');

    function Poller(scope, request) {
      this.deferred = $q.defer();
      this.request = request;
      this.scope = scope;

      scope.$on('$destroy', this.stop.bind(this));

      this.latestResult = undefined;
      this.isCanceled = undefined;
      this.timeout = undefined;
      this.stateChangeStartBind = undefined;
      this.cache = undefined;
    }

    Poller.prototype.doCall = doCall;
    Poller.prototype.setExtractInterval = setExtractInterval;
    Poller.prototype.cycle = cycle;
    Poller.prototype.doCycle = doCycle;
    Poller.prototype.stop = stop;
    Poller.prototype.subscribe = subscribe;
    Poller.prototype.keepIn = keepIn;
    Poller.prototype.showSpinner = showSpinner;
    Poller.prototype.reload = reload;

    return Poller;

    function setExtractInterval(interval) {
      this.extractInterval = interval;
      return this;
    }
    function reload(vm) {
      this.stop();
      this.isCanceled = false;
      this.key && this.keepIn(this.key, vm);
      this.doCycle();
      return this;
    }
    function showSpinner(vm) {
      var self = this;
      mnPromiseHelper(vm, self.doCallPromise).showSpinner();
      return self;
    }
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
      this.doCycle();
      return this;
    }
    function doCycle() {
      var self = this;
      if (self.extractInterval) {
        if (angular.isFunction(self.extractInterval)) {
          self.doCallPromise = self.doCall().then(function (result) {
            if (self.isCanceled) {
              return;
            }
            var interval = self.extractInterval(result);
            self.timeout = $timeout(self.doCycle.bind(self), interval);
          });
        } else {
          self.timeout = $timeout(self.doCycle.bind(self), self.extractInterval);
          self.doCallPromise = self.doCall();
        }
      } else {
        self.doCallPromise = mnTasksDetails.getFresh().then(function (result) {
          if (self.isCanceled) {
            return;
          }
          var interval = (_.chain(result.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
          self.timeout = $timeout(self.doCycle.bind(self), interval);
          return self.doCall();
        });
      }
      return this;
    }
    function stop() {
      var self = this;
      self.stateChangeStartBind && this.stateChangeStartBind();
      self.isCanceled = true;
      $timeout.cancel(self.timeout);
    }
    function subscribe(subscriber, keeper) {
      var self = this;
      self.subscriber = subscriber;
      self.deferred.promise.then(null, null, angular.isFunction(subscriber) ? function (value) {
        subscriber(value, self.latestResult);
        self.latestResult = value;
      } : function (value) {
        (keeper || self.scope)[subscriber] = value;
        self.latestResult = value;
      });
      return self;
    }
    function keepIn(key, vm) {
      var self = this;
      self.key = key;
      self.cache = $cacheFactory.get("stateKeeper").get(key);
      if (self.cache) {
        if (angular.isFunction(self.subscriber)) {
          self.subscriber(self.cache);
        } else {
          (vm || self.scope)[self.subscriber] = self.cache;
        }
      }

      self.stateChangeStartBind = $rootScope.$on('$stateChangeStart', function (event, toState) {
        if (!(toState.name.indexOf(key) > -1)) {
          $cacheFactory.get("stateKeeper").remove(key);
        } else {
          $cacheFactory.get("stateKeeper").put(key, self.latestResult);
        }
      });

      return self;
    }
  }
})();
