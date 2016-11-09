(function () {
  "use strict";

  angular
    .module("mnRouter", ["ui.router"])
    .provider("mnRouter", mnRouterProvider);

  function mnRouterProvider($stateProvider) {
    this.$get = $get;
    function $get($state) {
      return {
        getStateProvider: function addState() {
          return $stateProvider;
        }
      };
    }
  }
})();
