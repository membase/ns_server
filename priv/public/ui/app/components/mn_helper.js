(function () {
  "use strict";

  angular
    .module('mnHelper', [
      'ui.router',
      'mnTasksDetails',
      'mnAlertsService'
    ])
    .factory('mnHelper', mnHelperFactory);

  function mnHelperFactory($window, $state, $stateParams, $location, $timeout, $q, mnTasksDetails, mnAlertsService, $http, mnPendingQueryKeeper) {
    var mnHelper = {
      wrapInFunction: wrapInFunction,
      calculateMaxMemorySize: calculateMaxMemorySize,
      initializeDetailsHashObserver: initializeDetailsHashObserver,
      checkboxesToList: checkboxesToList,
      reloadApp: reloadApp,
      reloadState: reloadState
    };

    return mnHelper;

    function wrapInFunction(value) {
      return function () {
        return value;
      };
    }
    function calculateMaxMemorySize(totalRAMMegs) {
      return Math.floor(Math.max(totalRAMMegs * 0.8, totalRAMMegs - 1024));
    }
    function initializeDetailsHashObserver($scope, hashKey, stateName) {
      function getHashValue() {
        return $stateParams[hashKey] || [];
      }
      $scope.isDetailsOpened = function (hashValue) {
        return _.contains(getHashValue(), String(hashValue));
      };
      $scope.toggleDetails = function (hashValue) {
        var currentlyOpened = getHashValue();
        var stateParams = {};
        if ($scope.isDetailsOpened(hashValue)) {
          stateParams[hashKey] = _.difference(currentlyOpened, [String(hashValue)]);
          $state.go(stateName, stateParams, {notify: false});
        } else {
          currentlyOpened.push(String(hashValue));
          stateParams[hashKey] = currentlyOpened;
          $state.go(stateName, stateParams, {notify: false});
        }
      };
    }
    function checkboxesToList(object) {
      return _.chain(object).pick(angular.identity).keys().value();
    }
    function reloadApp() {
      $window.location.reload();
    }
    function reloadState() {
      mnPendingQueryKeeper.cancelAllQueries();
      $state.transitionTo($state.current, $stateParams, {reload: true, inherit: true, notify: true});
    }
  }
})();
