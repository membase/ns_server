(function () {
  "use strict";

  angular
    .module("mnFilter", [])
    .directive("mnFilter", mnFilterDirective);

  function mnFilterDirective($window) {
    var mnFilter = {
      restrict: "A",
      scope: {
        items: "=",
        mnFilter: "=",
        disabled: "=",
        onClose: "&",
        onOpen: "&",
        onReset: "&"
      },
      templateUrl: "app/components/directives/mn_filter/mn_filter.html",
      controller: mnFilterController,
      controllerAs: "mnFilterController",
      bindToController: true
    };

    return mnFilter;

    function mnFilterController($scope) {
      var vm = this;

      vm.togglePopup = togglePopup;
      vm.stopEvent = stopEvent;

      activate();

      function stopEvent($event) {
        $event.stopPropagation();
      }

      function onClose() {
        vm.onClose({params: vm.mnFilter});
      }

      function togglePopup() {
        vm.showPopup = !vm.showPopup;
        if (vm.showPopup) {
          vm.onOpen && vm.onOpen();
        } else {
          vm.onClose && onClose();
        }
      }

      function activate() {
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
