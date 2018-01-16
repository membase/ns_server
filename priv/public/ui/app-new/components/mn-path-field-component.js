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
      mn.services.MnWizard
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

    function MnPathField(mnWizardService) {
      this.focusField = true;
      this.createLookUpStream = mnWizardService.createLookUpStream.bind(mnWizardService);
    }
  })();
