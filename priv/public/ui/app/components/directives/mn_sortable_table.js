(function () {
  "use strict";

  angular
    .module('mnSortableTable', [])
    .directive('mnSortableTable', mnSortableTableDirective)
    .directive('mnSortableTitle', mnSortableTitleDirective)
    .factory('mnSortableTable', mnSortableTableFactory)

  function mnSortableTableFactory() {
    var properties = {
      orderBy: null,
      invert: null
    };
    var rv = {
      isOrderBy: isOrderBy,
      setOrder: setOrder,
      get: get
    };

    return rv;

    function get() {
      return properties;
    }
    function isOrderBy(orderBy) {
      return properties.orderBy === orderBy;
    }
    function setOrder(orderBy) {
      if (!isOrderBy(orderBy)) {
        properties.invert = false;
      } else {
        properties.invert = !properties.invert;
      }
      properties.orderBy = orderBy;
    }
  }

  function mnSortableTitleDirective($compile, mnSortableTable) {
    var mnSortableTitle = {
      require: '^mnSortableTable',
      link: link,
      controller: controller,
      controllerAs: "controller",
      bindToController: true,
      scope: true
    };

    return mnSortableTitle;

    function controller() {
      var vm = this;
      vm.setOrder = mnSortableTable.setOrder;
      vm.isOrderBy = mnSortableTable.isOrderBy;
    }


    function link($scope, $element, $attrs) {
      var mnSortableTitle = $attrs.mnSortableTitle;
      $element.removeAttr("mn-sortable-title");
      $attrs.$set('ngClick', 'controller.setOrder("' + mnSortableTitle +'")');
      $attrs.$set('ngClass', '{dynamic_active: controller.isOrderBy("' + mnSortableTitle + '")}');
      $compile($element)($scope);
    }
  }

  function mnSortableTableDirective() {
    var mnSortableTable = {
      controller: controller,
    };

    return mnSortableTable;

    function controller($scope, $element, $attrs, mnSortableTable) {
      mnSortableTable.setOrder($attrs.mnSortableTable);
    }
  }
})();
