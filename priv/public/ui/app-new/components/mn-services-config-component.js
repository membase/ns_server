var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnServicesConfig =
  (function () {
    "use strict";

    MnServicesConfig.annotations = [
      new ng.core.Component({
        selector: "mn-services-config",
        templateUrl: "app-new/components/mn-services-config.html",
        inputs: [
          "group",
          "servicesOnly"
        ]
      })
    ];

    MnServicesConfig.parameters = [
      mn.services.MnWizard,
      mn.services.MnAdmin
    ];

    MnServicesConfig.prototype.ngOnInit = ngOnInit;
    MnServicesConfig.prototype.ngOnDestroy = ngOnDestroy;

    return MnServicesConfig;

    function ngOnInit() {
      if (this.servicesOnly) {
        return
      }
      this.total =
        this.group
        .valueChanges
        .map(calculateTotal.bind(this));

      createToggleFieldStream.bind(this)("kv");
      createToggleFieldStream.bind(this)("index");
      createToggleFieldStream.bind(this)("fts");
      createToggleFieldStream.bind(this)("cbas");

      this.group
        .valueChanges
        .debounce(function () {
          return Rx.Observable.interval(300);
        })
        .takeUntil(this.destroy)
        .subscribe(validate.bind(this))

      //trigger servicesGroup.valueChanges in order to calculate total
      setTimeout(triggerUpdate.bind(this), 0);
    }

    function validate() {
      var data = {};
      maybeAddQuota.bind(this)(data, "memoryQuota", "kv");
      maybeAddQuota.bind(this)(data, "indexMemoryQuota", "index");
      maybeAddQuota.bind(this)(data, "ftsMemoryQuota", "fts");
      maybeAddQuota.bind(this)(data, "cbasMemoryQuota", "cbas");
      this.poolsDefaultHttp.post([data, true]);
    }

    function maybeAddQuota(data, name, serviceName) {
      var service = this.group.get("flag." + serviceName);
      if (service && service.value) {
        data[name] = this.group.get("field." + serviceName).value;
      }
    }

    function calculateTotal(value) {
      return getFieldValue("kv", this.group) +
        getFieldValue("index", this.group) +
        getFieldValue("fts", this.group) +
        getFieldValue("cbas", this.group);
    }

    function getFieldValue(serviceName, group) {
      var flag = group.get("flag." + serviceName);
      var field = group.get("field." + serviceName);
      return (flag && flag.value && field.value) || 0;
    }

    function createToggleFieldStream(serviceGroupName) {
      var group = this.group.get("flag." + serviceGroupName);
      if (group) {
        group
          .valueChanges
          .takeUntil(this.destroy)
          .subscribe(toggleFields(serviceGroupName).bind(this));
      }
    }

    function toggleFields(serviceGroupName) {
      return function () {
        this.group.get("field." + serviceGroupName)
        [this.group.get("flag." + serviceGroupName).value ? "enable" : "disable"]({onlySelf: true});
      }
    }

    function triggerUpdate() {
      this.group.patchValue(this.group.value);
    }

    function ngOnDestroy() {
      this.destroy.next();
      this.destroy.complete();
    }

    function MnServicesConfig(mnWizardService, mnAdminService) {
      this.focusField = true;
      this.destroy = new Rx.Subject();
      this.poolsDefaultHttp = mnAdminService.stream.poolsDefaultHttp;
    }
  })();
