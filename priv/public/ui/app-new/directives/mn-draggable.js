var mn = mn || {};
mn.directives = mn.directives || {};
mn.directives.MnDraggable =
  (function () {
    "use strict";

    MnFocusDirective.annotations = [
      new ng.core.Directive({
        selector: "[mnDraggable]",
        inputs: [
          "baseCornerRight"
        ],
        host: {
          '[style.top]': 'top',
          '[style.right]': 'right',
          '[style.left]': 'left',
          '[style.bottom]': 'bottom',
          '(mousedown)': 'mousedown($event)',
          '(document:mousemove)': 'mousemove($event)',
          '(document:mouseup)': 'mouseup($event)',
        }
      })
    ];

    MnFocusDirective.parameters =[
      ng.core.ElementRef
    ];

    MnFocusDirective.prototype.mousedown = mousedown;
    MnFocusDirective.prototype.mouseup = mouseup;
    MnFocusDirective.prototype.mousemove = mousemove;
    MnFocusDirective.prototype.ngOnDestroy = ngOnDestroy;

    return MnFocusDirective;

    function MnFocusDirective(el) {
      var that = this;
      this.stream = {};
      this.stream.mouseup = new Rx.Subject();;
      this.stream.mousemove = new Rx.Subject();;
      this.stream.mousedown = new Rx.Subject();;
      this.destroy = new Rx.Subject();

      that.stream
        .mousedown
        .map(function (e) {
          var target = e.currentTarget;
          var startX = target.offsetLeft;

          if (that.baseCornerRight) {
            startX += target.clientWidth;
          }
          return {
            startX: startX,
            startY: target.offsetTop,
            mouseX: e.clientX,
            mouseY: e.clientY
          };
        }).switchMap(function (init) {
          return that.stream
            .mousemove
            .takeUntil(that
                       .stream
                       .mouseup)
            .map(function (e) {
              var dx = e.clientX - init.mouseX;
              var dy = e.clientY - init.mouseY;
              var rv = {
                top: init.startY + dy + 'px',
                bottom: 'auto'
              };
              if (that.baseCornerRight) {
                rv.right = -(init.startX + dx) + 'px';
                rv.left = "auto";
              } else {
                rv.right = "auto";
                rv.left = init.startX + dx + 'px';
              }
              return rv;
            });
        })
        .takeUntil(this.destroy)
        .subscribe(function (css) {
          that.top = css.top;
          that.bottom = css.bottom;
          that.left = css.left;
          that.right = css.right;
        });
    }

    function mousedown(e) {
      this.stream.mousedown.next(e);
      return false;
    }

    function mouseup(e) {
      this.stream.mouseup.next(e);
    }

    function mousemove(e) {
      this.stream.mousemove.next(e);
      return false;
    }

    function ngOnDestroy() {
      this.destroy.next();
      this.destroy.complete();
    }
  })();
