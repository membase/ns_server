(function () {
  "use strict";

  angular
    .module("mnFilter", ["ui.router"])
    .directive("mnFilter", mnFilterDirective);

  function mnFilterDirective($window, $state) {
    var mnFilter = {
      restrict: "A",
      scope: {
        items: "=",
        mnFilter: "@",
        disabled: "=",
        passParams: "&"
      },
      templateUrl: "components/directives/mn_filter/mn_filter.html",
      controller: mnFilterController,
      controllerAs: "mnFilterController",
      bindToController: true
    };

    return mnFilter;

    function mnFilterController($scope) {
      var vm = this;

      vm.togglePopup = togglePopup;
      vm.stopEvent = stopEvent;
      vm.reset = reset;

      activate();

      function stopEvent($event) {
        $event.stopPropagation();
      }

      function reset() {
        vm.params = {};
      }

      function passParams() {
        vm.passParams({params: _.transform(_.clone(vm.params), function (result, n, key) {
          if (n === "") {
            return;
          }
          result[key] = n;
        })});
      }

      function togglePopup() {
        vm.showPopup = !vm.showPopup;
      }

      function activate() {
        try {
          vm.params = JSON.parse($state.params[vm.mnFilter]) || {};
        } catch (e) {
          vm.params = {};
        }
        $scope.$watch("mnFilterController.params", passParams, true);

        angular.element($window).on("click", function () {
          if (vm.showPopup) {
            togglePopup();
            $scope.$apply();
          }
        });
      }
    }
  }
})();
