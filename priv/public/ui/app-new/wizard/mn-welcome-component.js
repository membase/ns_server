var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnWelcome =
  (function () {
    "use strict";

    MnWelcomeComponent.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/wizard/mn-welcome.html",
      })
    ];

    MnWelcomeComponent.parameters = [
      mn.services.MnAdmin
    ];

    return MnWelcomeComponent;

    function MnWelcomeComponent(mnAdmin) {
      this.focusField = true;

      this.prettyVersion =
        mnAdmin
        .stream
        .prettyVersion;
    }
  })();
