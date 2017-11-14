var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnShared =
  (function () {
    "use strict";

    MnSharedModule.annotations = [
      new ng.core.NgModule({
        declarations: [
          mn.directives.MnFocus
        ],
        exports: [
          mn.directives.MnFocus
        ]
      })
    ];

    return MnSharedModule;

    function MnSharedModule() {
    }
  })();
