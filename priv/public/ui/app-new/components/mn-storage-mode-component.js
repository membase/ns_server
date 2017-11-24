var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnStorageMode =
  (function () {
    "use strict";

    MnStorageMode.annotations = [
      new ng.core.Component({
        selector: "mn-storage-mode",
        templateUrl: "app-new/components/mn-storage-mode.html",
        inputs: [
          "control",
          "indexFlagChanges",
          "permissionsIndexWrite",
          "isAtLeast50"
        ]
      })
    ];

    MnStorageMode.parameters = [
      mn.services.MnWizard,
      mn.services.MnPools
    ];

    MnStorageMode.prototype.ngOnInit = ngOnInit;
    MnStorageMode.prototype.ngOnDestroy = ngOnDestroy;

    return MnStorageMode;

    function ngOnDestroy() {
      this.destroy.next();
      this.destroy.complete();
    }

    function ngOnInit() {
      var isNotEnterprise =
          this.isEnterprise
          .map(mn.helper.invert);

      var isFirstValueForestDB =
          this.control
          .valueChanges
          .first()
          .map(function (v) {
            return v === 'forestdb'
          })

      this.showForestDB =
        Rx.Observable.combineLatest(
          isNotEnterprise,
          isFirstValueForestDB
        )
        .map(_.curry(_.some)(_, Boolean));

      this.showPlasma =
        Rx.Observable.combineLatest(
          this.isEnterprise,
          this.isAtLeast50 || Rx.Observable.of(true)
        )
        .map(_.curry(_.every)(_, Boolean))

      Rx.Observable.combineLatest(
        isNotEnterprise,
        (this.indexFlagChanges || Rx.Observable.of(true)).map(mn.helper.invert),
        (this.permissionsIndexWrite || Rx.Observable.of(true)).map(mn.helper.invert)
      )
        .map(_.curry(_.some)(_, Boolean))
        .takeUntil(this.destroy).subscribe(doDisableControl.bind(this));
    }

    function doDisableControl(value) {
      this.control[value ? "disable" : "enable"]();
    }

    function MnStorageMode(mnWizardService, mnPoolsService) {
      this.destroy = new Rx.Subject();
      this.indexesHttp = mnWizardService.stream.indexesHttp;
      this.isEnterprise = mnPoolsService.stream.isEnterprise;
    }

  })();
