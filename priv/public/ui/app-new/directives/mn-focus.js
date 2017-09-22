var mn = mn || {};
mn.directives = mn.directives || {};
mn.directives.MnFocus =
  (function () {
    "use strict";

    var MnFocusDirective =
        ng.core.Directive({
          selector: "[mnFocus]",
          inputs: [
            "mnFocus"
          ],
          outputs: [
            "mnFocusChange"
          ],
          host: {
            '(blur)': 'blur()'
          }
        })
        .Class({
          constructor: [
            ng.core.ElementRef,
            function MnFocusDirective(el) {
              this.mnFocusChange = new ng.core.EventEmitter();
              this.element = el.nativeElement;
            }],
          ngOnChanges: function () {
            if (this.mnFocus) {
              this.element.focus();
            }
          },
          blur: function () {
            this.mnFocusChange.emit(false);
          }
        });

    return MnFocusDirective;
  })();
