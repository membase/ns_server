var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnQuerySettingsConfig =
  (function () {
    "use strict";

    MnQuerySettingsConfig.annotations = [
      new ng.core.Component({
        selector: "mn-query-settings-config",
        templateUrl: "app-new/components/mn-query-settings-config.html",
        inputs: [
          "group"
        ]
      })
    ];

    MnQuerySettingsConfig.parameters = [
      mn.services.MnWizard,
      ng.core.ChangeDetectorRef
    ];

    MnQuerySettingsConfig.prototype.ngOnChanges = ngOnChanges;

    return MnQuerySettingsConfig;

    function ngOnChanges() {
      this.changeDetector.detectChanges();
    }

    function MnQuerySettingsConfig(mnWizardService, changeDetector) {
      this.changeDetector = changeDetector;
      this.querySettingsHttp = mnWizardService.stream.querySettingsHttp;
    }
  })();
