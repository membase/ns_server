var mn = mn || {};
mn.directives = mn.directives || {};
mn.directives.MnFocus =
  (function () {
    "use strict";

    MnFocusDirective.annotations = [
      new ng.core.Directive({
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
    ];

    MnFocusDirective.parameters = [
      ng.core.ElementRef
    ];

    MnFocusDirective.prototype.ngOnChanges = ngOnChanges;
    MnFocusDirective.prototype.blur = blur;

    return MnFocusDirective;

    function MnFocusDirective(el) {
      this.mnFocusChange = new ng.core.EventEmitter();
      this.element = el.nativeElement;
    }

    function ngOnChanges() {
      if (this.mnFocus) {
        this.element.focus();
      }
    }

    function blur() {
      this.mnFocusChange.emit(false);
    }
  })();
