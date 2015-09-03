angular.module('mnDragAndDrop', [
]).directive('mnDragAndDrop', function ($document, $window) {

  return {
    scope: {
      onItemTaken: '&',
      onItemDropped: '&',
      onItemMoved: '&'
    },
    link: function ($scope, $element, $attrs) {
      var draggedObject;
      var startX;
      var startY;
      var initialMouseX;
      var initialMouseY;

      $element.bind('mousedown touchstart', function (e) {
        e = e || $window.event;

        var target = e.currentTarget;
        if (draggedObject) {
          releaseElement();
          return;
        }
        draggedObject = $element;
        if ($scope.onItemTaken) {
          $scope.onItemTaken({$event: e});
        }
        startX = target.offsetLeft;
        startY = target.offsetTop;
        initialMouseX = e.clientX;
        initialMouseY = e.clientY;

        $element.addClass("dragged");

        $document.bind('mousemove touchmove', dragMouse);
        $document.bind('mouseup touchend', releaseElement);
        return false;
      });

      function dragMouse(e) {
        e = e || window.event;
        if ($scope.onItemMoved) {
          $scope.onItemMoved(this);
        }
        var dX = e.clientX - initialMouseX;
        var dY = e.clientY - initialMouseY;
        setPosition(dX, dY);
        return false;
      }
      function setPosition(dx, dy) {
        $element.css({left: startX + dx + 'px', top: startY + dy + 'px'});
      }
      function releaseElement() {
        if ($scope.onItemDropped) {
          $scope.onItemDropped(this);
        }
        $document.unbind('mousemove touchmove mouseup touchend');
        draggedObject.removeClass("dragged");
        draggedObject = null;
      }
    }
  };
});