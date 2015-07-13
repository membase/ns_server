angular.module('mnSortableTable', [
  ]).directive('mnSortableTable', function () {

  return {
    controller: function ($scope, $element, $attrs) {
      $scope.isOrderBy = function (orderBy) {
        return $scope.orderBy === orderBy;
      };

      $scope.setOrder = function (orderBy) {
        if (!$scope.isOrderBy(orderBy)) {
          $scope.invert = false;
        } else {
          $scope.invert = !$scope.invert;
        }
        $scope.orderBy = orderBy;
      };

      $scope.setOrder($attrs.mnSortableTable);
    }
  };
}).directive('mnSortableTitle', function ($compile) {

  return {
    require: '^mnSortableTable',
    link: function ($scope, $element, $attrs) {
      var setOrder = $attrs.mnSortableTitle;
      $element.removeAttr("mn-sortable-title");
      $attrs.$set('ngClick', 'setOrder("' + setOrder +'")');
      $attrs.$set('ngClass', '{dynamic_active: isOrderBy("' + setOrder + '")}');
      $compile($element)($scope);
    }
  }
});