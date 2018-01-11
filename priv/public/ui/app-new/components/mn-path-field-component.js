var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnPathField =
  (function () {
    "use strict";

    MnPathField.annotations = [
      new ng.core.Component({
        selector: "mn-path-field",
        templateUrl: "app-new/components/mn-path-field.html",
        inputs: [
          "control",
          "controlName"
        ]
      })
    ];

    MnPathField.parameters = [
      mn.services.MnWizard,
      ng.core.ChangeDetectorRef
    ];

    MnPathField.prototype.ngOnInit = ngOnInit;

    return MnPathField;

    function ngOnInit() {
      this.lookUpPath = this.createLookUpStream(this.control.valueChanges);
      setTimeout(function () {
        //trigger storageGroup.valueChanges for lookUpIndexPath,lookUpDBPath
        this.control.setValue(this.control.value);
      }.bind(this), 0);
    }

    function MnPathField(mnWizardService, changeDetector) {
      this.focusField = true;
      this.changeDetector = changeDetector;
      this.createLookUpStream = mnWizardService.createLookUpStream.bind(mnWizardService);
    }
  })();
