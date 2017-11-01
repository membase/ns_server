var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnShared =
  (function () {
    "use strict";

    var MnShared =
        ng.core.NgModule({
          declarations: [
            mn.directives.MnFocus
          ],
          exports: [
            mn.directives.MnFocus
          ]
        })
        .Class({
          constructor: function MnSharedModule() {},
        });

    return MnShared;
  })();
