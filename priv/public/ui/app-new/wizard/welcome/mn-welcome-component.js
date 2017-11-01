var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnWelcome =
  (function () {
    "use strict";

    var MnWelcome =
        ng.core.Component({
          templateUrl: "app-new/wizard/welcome/mn-welcome.html",
        })
        .Class({
          constructor: [
            mn.services.MnAdmin,
            function MnWelcomeComponent(mnAdmin) {
              this.focusField = true;

              this.prettyVersion =
                mnAdmin
                .stream
                .prettyVersion;
            }]
        });

    return MnWelcome;
  })();
