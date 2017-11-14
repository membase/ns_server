var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnNewClusterConfig =
  (function () {
    "use strict";

    MnNewClusterConfig.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/wizard/mn-new-cluster-config/mn-new-cluster-config.html"
      })
    ];

    MnNewClusterConfig.parameters = [
      mn.services.MnWizard,
      mn.services.MnAdmin,
      mn.services.MnPools,
      mn.services.MnApp
    ];

    MnNewClusterConfig.prototype.onSubmit = onSubmit;

    return MnNewClusterConfig;

    function onSubmit() {
      if (this.mnAppLoding.getValue()) {
        return;
      }

      clearErrors.bind(this)();

      showLoading.bind(this)()
        .subscribe(this.mnAppLoding.next.bind(this.mnAppLoding));

      whenAllRequestSuccessed.bind(this)()
        .subscribe(function (result) {
          console.log(result)
        });

      this.poolsDefaultHttp.post([getPoolsDefaultValues.bind(this)(), false]);

      this.servicesHttp.post(getServicesValues.bind(this)());

      this.indexesHttp.post({
        storageMode: this.wizardForm.newClusterConfig.get("storageMode").value
      });

      this.hostnameHttp.post(
        this.wizardForm.newClusterConfig.get("clusterStorage.hostname").value);

      this.diskStorageHttp.post(
        this.wizardForm.newClusterConfig.get("clusterStorage.storage").value);

      this.statsHttp.post(
        this.wizardForm.newClusterConfig.get("enableStats").value);

      if (this.wizardForm.termsAndConditions.get("register").value) {
        this.emailHttp
          .response
          .first()
          .subscribe(console.log);
        this.prettyVersion.first().subscribe((function (version) {
          this.emailHttp.post([
            this.wizardForm.termsAndConditions.get("user").value, version]);
        }).bind(this));
      }
    }

    function clearErrors() {
      this.poolsDefaultHttp.clearError();
      this.diskStorageHttp.clearError();
      this.hostnameHttp.clearError();
      this.indexesHttp.clearError();
      this.servicesHttp.clearError();
      this.statsHttp.clearError();
    }

    function showLoading() {
      return Rx.Observable
        .zip
        .apply(null, getHttpGroupStreams.bind(this)("response"))
        .first()
        .mapTo(false)
        .startWith(true);
    }

    function whenAllRequestSuccessed() {
      return Rx.Observable
        .zip
        .apply(null, getHttpGroupStreams.bind(this)("success"))
        .first()
        .takeUntil(Rx.Observable
                   .merge
                   .apply(null, getHttpGroupStreams.bind(this)("error")));
    }

    function getHttpGroupStreams(name) {
      return [
        this.poolsDefaultHttp[name],
        this.diskStorageHttp[name],
        this.hostnameHttp[name],
        this.statsHttp[name],
        this.indexesHttp[name],
        this.servicesHttp[name]
      ];
    }

    function getPoolsDefaultValues() {
      return _.reduce([
        ["memoryQuota", "kv"],
        ["indexMemoryQuota", "index"],
        ["ftsMemoryQuota", "fts"]
      ], getPoolsDefaultValue.bind(this), {
        clusterName: this.wizardForm.newCluster.get("clusterName").value
      });
    }

    function getPoolsDefaultValue(result, names) {
      var service = this.wizardForm.newClusterConfig.get("services.flag." + names[1]);
      if (service && service.value) {
        result[names[0]] =
          this.wizardForm.newClusterConfig.get("services.field." + names[1]).value;
      }
      return result;
    }

    function getServicesValues() {
      return _.reduce(
        ["kv", "index", "fts", "n1ql", "eventing"],
        getServicesValue.bind(this),
        []
      );
    }

    function getServicesValue(result, serviceName) {
      var service = this.wizardForm.newClusterConfig.get("services.flag." + serviceName);
      if (service && service.value) {
        result.push(serviceName);
      }
      return result;
    }

    function MnNewClusterConfig(mnWizardService, mnAdminService, mnPoolsService, mnAppService) {
      this.focusField = true;

      this.wizardForm = mnWizardService.wizardForm;

      this.mnAppLoding = mnAppService.stream.loading;

      this.newClusterConfigForm = mnWizardService.wizardForm.newClusterConfig;

      this.prettyVersion = mnAdminService.stream.prettyVersion;

      this.poolsDefaultHttp = mnAdminService.stream.poolsDefaultHttp;
      this.hostnameHttp = mnWizardService.stream.hostnameHttp;
      this.diskStorageHttp = mnWizardService.stream.diskStorageHttp;
      this.indexesHttp = mnWizardService.stream.indexesHttp;
      this.servicesHttp = mnWizardService.stream.servicesHttp;
      this.statsHttp = mnWizardService.stream.statsHttp;
      this.emailHttp = mnWizardService.stream.emailHttp;

      this.totalRAMMegs = mnWizardService.stream.totalRAMMegs;
      this.maxRAMMegs = mnWizardService.stream.maxRAMMegs;

      this.isButtonDisabled =
        this.poolsDefaultHttp.error.map(function (error) {
          return error && !_.isEmpty(error.errors);
        });
    }
  })();
