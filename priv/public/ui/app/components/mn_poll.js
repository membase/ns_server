(function () {
  "use strict";

  angular
    .module("mnPoll", [
      "mnTasksDetails",
      "mnPromiseHelper"
    ])
    .factory("mnPoller", mnPollerFactory)
    .factory("mnEtagPoller", mnEtagPollerFactory);

  function mnEtagPollerFactory(mnPoller) {
    function EtagPoller(scope, request) {
      mnPoller.call(this, scope, request);
    }

    EtagPoller.prototype = Object.create(mnPoller.prototype);
    EtagPoller.prototype.constructor = EtagPoller;
    EtagPoller.prototype.cycle = cycle;

    return EtagPoller;

    function cycle() {
      var self = this;
      var timestamp = new Date();
      self.doCallPromise = self.doCall(timestamp);
      self.doCallPromise.then(function () {
        if (self.isStopped(timestamp)) {
          return;
        }
        self.cycle();
      });
    }
  }

  function mnPollerFactory($q, $timeout, mnTasksDetails, mnPromiseHelper) {

    function Poller(scope, request) {
      this.deferred = $q.defer();
      this.request = request;
      this.scope = scope;

      scope.$on('$destroy', this.stop.bind(this));

      this.latestResult = undefined;
      this.stopTimestamp = undefined;
      this.extractInterval = undefined;
      this.timeout = undefined;
      this.doCallPromise = undefined;
    }

    Poller.prototype.isStopped = isStopped;
    Poller.prototype.doCall = doCall;
    Poller.prototype.setExtractInterval = setExtractInterval;
    Poller.prototype.cycle = cycle;
    Poller.prototype.doCycle = doCycle;
    Poller.prototype.stop = stop;
    Poller.prototype.subscribe = subscribe;
    Poller.prototype.showSpinner = showSpinner;
    Poller.prototype.reload = reload;
    Poller.prototype.reloadOnScopeEvent = reloadOnScopeEvent;

    return Poller;

    function isStopped(startTimestamp) {
      return !(angular.isUndefined(this.stopTimestamp) || startTimestamp >= this.stopTimestamp);
    }
    function reloadOnScopeEvent(eventName, vm, spinnerName) {
      var self = this;
      self.scope.$on(eventName, function () {
        self.reload(vm).showSpinner(vm, spinnerName);
      });
      return this;
    }
    function setExtractInterval(interval) {
      this.extractInterval = interval;
      return this;
    }
    function reload(vm) {
      this.stop();
      this.doCycle();
      return this;
    }
    function showSpinner(vm, name) {
      var self = this;
      mnPromiseHelper(vm, self.doCallPromise).showSpinner(name);
      return self;
    }
    function doCall(timestamp) {
      var self = this;
      var query = angular.isFunction(self.request) ? self.request(self.latestResult) : self.request;
      query.then(function (result) {
        if (self.isStopped(timestamp)) {
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
      var timestamp = new Date();

      self.doCallPromise = self.doCall(timestamp);

      if (self.extractInterval) {
        if (angular.isFunction(self.extractInterval)) {
          self.doCallPromise.then(function (result) {
            if (self.isStopped(timestamp)) {
              return;
            }
            var interval = self.extractInterval(result);
            self.timeout = $timeout(self.doCycle.bind(self), interval);
          });
        } else {
          self.timeout = $timeout(self.doCycle.bind(self), self.extractInterval);
        }
      } else {
        mnTasksDetails.getFresh().then(function (result) {
          if (self.isStopped(timestamp)) {
            return;
          }
          //recommendedRefreshPeriod should be implemented only for tasks poller,
          //for dependent pollers better to use scope.$watch("adminCtl.tasks");
          //in conjunction with some static extractInterval (e.g. 10000)
          var interval = (_.chain(result.tasks).pluck('recommendedRefreshPeriod').compact().min().value() * 1000) >> 0 || 10000;
          self.timeout = $timeout(self.doCycle.bind(self), interval);
        });
      }
      self.doCallPromise.then(null, function (resp) {
        self.stop(); //stop cycle on any http error;
      });
      return this;
    }
    function stop() {
      var self = this;
      self.stopTimestamp = new Date();
      $timeout.cancel(self.timeout);
    }
    function subscribe(subscriber, keeper) {
      var self = this;
      self.deferred.promise.then(null, null, angular.isFunction(subscriber) ? function (value) {
        subscriber(value, self.latestResult);
        self.latestResult = value;
      } : function (value) {
        (keeper || self.scope)[subscriber] = value;
        self.latestResult = value;
      });
      return self;
    }
  }
})();
