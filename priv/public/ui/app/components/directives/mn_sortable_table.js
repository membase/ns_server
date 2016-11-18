(function () {
  "use strict";

  angular
    .module('mnSortableTable', [])
    .directive('mnSortableTable', mnSortableTableDirective)
    .directive('mnSortableTitle', mnSortableTitleDirective)

  function mnSortableTitleDirective($compile) {
    var mnSortableTitle = {
      require: '^mnSortableTable',
      transclude: 'element',
      restrict: 'A',
      link: link,
      scope: {
        sortFunction: "&?",
        mnSortableTitle: "@?"
      }
    };

    return mnSortableTitle;

    function link($scope, $element, $attrs, ctl, $transclude) {
      $scope.mnSortableTable = ctl;
      if ($attrs.sortByDefault) {
        ctl.setOrderOrToggleInvert(
          $scope.mnSortableTitle || $scope.sortFunction,
          $scope.mnSortableTitle
        );
      }

      $transclude(function (cloned) {
        cloned.attr(
          'ng-click',
          'mnSortableTable.setOrderOrToggleInvert(mnSortableTitle || sortFunction, mnSortableTitle)'
        );
        cloned.removeAttr('mn-sortable-title');
        $element.after($compile(cloned)($scope));
      });
    }
  }

  function mnSortableTableDirective() {
     var mnSortableTable = {
       transclude: 'element',
       restrict: 'A',
       link: link,
       controller: controller,
       controllerAs: "mnSortableTable"
    };

    return mnSortableTable;

    function controller($scope, $element, $attrs) {
      var currentSortableTitle;
      var vm = this;

      vm.sortableTableProperties = {
        orderBy: null,
        invert: null
      };
      vm.setOrderOrToggleInvert = setOrderOrToggleInvert;

      function isOrderBy(name) {
        return currentSortableTitle === name;
      }
      function setOrderOrToggleInvert(orderBy, name) {
        if (isOrderBy(name)) {
          vm.sortableTableProperties.invert = !vm.sortableTableProperties.invert;
        } else {
          vm.sortableTableProperties.invert = false;
        }
        setOrder(orderBy, name);
      }
      function setOrder(orderBy, name) {
        currentSortableTitle = name;
        vm.sortableTableProperties.orderBy = orderBy;
      }
    }

    function link($scope, $element, $attrs, ctl, $transclude) {
      $element.after($transclude());
    }
  }
})();
