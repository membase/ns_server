var mn = mn || {};
mn.directives = mn.directives || {};
mn.directives.MnDraggable =
  (function () {
    "use strict";

    var MnDraggable =
        ng.core.Directive({
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
        .Class({
          constructor: [
            ng.core.ElementRef,
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

            }],
          mousedown: function (e) {
            this.stream.mousedown.next(e);
            return false;
          },
          mouseup: function (e) {
            this.stream.mouseup.next(e);
          },
          mousemove: function (e) {
            this.stream.mousemove.next(e);
            return false;
          },
          ngOnDestroy: function () {
            this.destroy.next();
            this.destroy.complete();
          },
        });

    return MnDraggable;
  })();
