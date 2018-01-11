var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnNodeStorageConfig =
  (function () {
    "use strict";

    MnNodeStorageConfig.annotations = [
      new ng.core.Component({
        selector: "mn-node-storage-config",
        templateUrl: "app-new/components/mn-node-storage-config.html",
        inputs: [
          "group"
        ]
      })
    ];

    MnNodeStorageConfig.parameters = [
      mn.services.MnWizard,
      ng.core.ChangeDetectorRef
    ];

    MnNodeStorageConfig.prototype.ngOnInit = ngOnInit;
    MnNodeStorageConfig.prototype.ngOnChanges = ngOnChanges;
    MnNodeStorageConfig.prototype.addCbasPathField = addCbasPathField;
    MnNodeStorageConfig.prototype.removeCbasPathField = removeCbasPathField;

    return MnNodeStorageConfig;

    function ngOnInit() {
      //trigger storageGroup.valueChanges for lookUpIndexPath,lookUpDBPath
      this.group.patchValue(this.group.value);
    }

    function ngOnChanges() {
      this.changeDetector.detectChanges();
    }

    function addCbasPathField() {
      var last = this.group.get('storage.cbas_path').length - 1;

      this.group
        .get('storage.cbas_path')
        .push(new ng.forms.FormControl(this.group.get('storage.cbas_path').value[last]));
    }

    function removeCbasPathField() {
      var last = this.group.get('storage.cbas_path').length - 1;
      this.group.get('storage.cbas_path').removeAt(last);
    }

    function MnNodeStorageConfig(mnWizardService, changeDetector) {
      this.focusField = true;
      this.changeDetector = changeDetector;
      this.hostnameHttp = mnWizardService.stream.hostnameHttp;
      this.diskStorageHttp = mnWizardService.stream.diskStorageHttp;
    }
  })();
