(function () {
  "use strict";

  angular
    .module('mnElementCrane', [])
    .service('mnElementCraneService', mnElementCraneFactory)
    .directive('mnElementDepot', mnElementDepotDirective)
    .directive('mnElementCargo', mnElementCargoDirective);

  function mnElementCargoDirective(mnElementCraneService) {
    var mnElementCargo = {
      restrict: 'E',
      link: mnElementCraneService.deliverCargo.bind(mnElementCraneService)
    };
    return mnElementCargo;
  }
  function mnElementDepotDirective(mnElementCraneService) {
    var mnElementCargo = {
      restrict: 'E',
      link: mnElementCraneService.registerDepot.bind(mnElementCraneService)
    };
    return mnElementCargo;
  }
  function mnElementCraneFactory() {
    var depots = {};

    var mnElementCraneService = {
      deliverCargo: deliverCargo,
      registerDepot: registerDepot
    };
    return mnElementCraneService;

    function registerDepot(scope, element, attrs) {
      depots[attrs.name] = element;
    }

    function deliverCargo(scope, element, attrs) {
      var depotElement = depots[attrs.depot];
      depotElement.append(element.contents());
      element.remove();
      scope.$on('$destroy', depotElement.empty.bind(depotElement));
    }
  }
})();
