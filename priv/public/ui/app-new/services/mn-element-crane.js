var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnElementCrane = (function () {
  "use strict";

  var depots = {};

  var MnElement =
      ng.core.Injectable()
      .Class({
        constructor: function MnElementCraneService() {},
        get: get,
        register: register,
        unregister: unregister
      });

  return MnElement;

  function register(element, name) {
    depots[name] = element;
  }

  function unregister(name) {
    delete depots[name]
  }

  function get(name) {
    return depots[name];
  }
})();

var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnElementCargo =
  (function () {
    "use strict";

    var MnElementCargo =
        ng.core.Component({
          selector: "mn-element-cargo",
          template: "<ng-content></ng-content>",
          inputs: [
            "depot"
          ],
        })
        .Class({
          constructor: [
            ng.core.ElementRef,
            ng.core.Renderer2,
            mn.services.MnElementCrane,
            function MnElementCargoComponent(el, renderer2, mnElementCrane) {
              this.el = el;
              this.renderer = renderer2;
              this.mnElementCrane = mnElementCrane;
            }],
          ngOnInit: function () {
            this.depotElement = this.mnElementCrane.get(this.depot);
            this.renderer.appendChild(this.depotElement.nativeElement, this.el.nativeElement);
          },
          ngOnDestroy: function () {
            this.renderer.removeChild(this.depotElement.nativeElement, this.el.nativeElement);
          },
        });

    return MnElementCargo;
  })();

var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnElementDepot =
  (function () {
    "use strict";

    var MnElementDepot =
        ng.core.Component({
          selector: "mn-element-depot",
          template: "<ng-content></ng-content>",
          inputs: [
            "name"
          ],
        })
        .Class({
          constructor: [
            ng.core.ElementRef,
            mn.services.MnElementCrane,
            function MnElementDepotComponent(el, mnElementCrane) {
              this.el = el;
              this.mnElementCrane = mnElementCrane;
            }],
          ngOnInit: function () {
            this.mnElementCrane.register(this.el, this.name);
          },
          ngOnDestroy: function () {
            this.mnElementCrane.unregister(this.name);
          },
        });

    return MnElementDepot;
  })();


var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnElementModule =
  (function () {
    "use strict";

    var MnElement =
        ng.core.NgModule({
          declarations: [
            mn.components.MnElementDepot,
            mn.components.MnElementCargo
          ],
          exports: [
            mn.components.MnElementDepot,
            mn.components.MnElementCargo
          ],
          imports: [],
          providers: [
            mn.services.MnElementCrane
          ]
        })
        .Class({
          constructor: function MnElementModule() {}
        });

    return MnElement;
  })();
