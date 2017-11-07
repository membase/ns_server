var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnNewClusterConfig =
  (function () {
    "use strict";

    mn.helper.extends(MnNewClusterConfig, mn.helper.MnDestroyableComponent);

    MnNewClusterConfig.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/wizard/mn-new-cluster-config.html"
      })
    ];

    MnNewClusterConfig.parameters = [
      mn.services.MnWizard,
      mn.services.MnAdmin,
      mn.services.MnPools,
      mn.services.MnApp,
      mn.services.MnAuth,
      window['@uirouter/angular'].UIRouter
    ];

    MnNewClusterConfig.prototype.onSubmit = onSubmit;
    MnNewClusterConfig.prototype.getWizardValues = getWizardValues;
    MnNewClusterConfig.prototype.getPoolsDefaultValues = getPoolsDefaultValues;

    return MnNewClusterConfig;

    function onSubmit() {
      if (this.mnAppLoding.getValue()) {
        return;
      }

      this.groupHttp.clearErrors();
      this.groupHttp.post(this.getWizardValues());
    }

    function getWizardValues() {
      return {
        poolsDefaultHttp: [
          this.getPoolsDefaultValues(),
          false
        ],
        servicesHttp: {
          services: this.getServicesValues(
            this.wizardForm.newClusterConfig.get("services.flag")
          ).join(","),
        },
        diskStorageHttp:this.wizardForm.newClusterConfig.get("clusterStorage.storage").value,
        hostnameHttp: this.wizardForm.newClusterConfig.get("clusterStorage.hostname").value,
        statsHttp: this.wizardForm.newClusterConfig.get("enableStats").value,
        querySettingsHttp: this.wizardForm.newClusterConfig.get("querySettings").value
      };
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

    function MnNewClusterConfig(mnWizardService, mnAdminService, mnPoolsService, mnAppService, mnAuthService, uiRouter) {
      mn.helper.MnDestroyableComponent.call(this);

      this.focusField = true;

      this.wizardForm = mnWizardService.wizardForm;

      this.mnAppLoding = mnAppService.stream.loading;

      this.newClusterConfigForm = mnWizardService.wizardForm.newClusterConfig;

      this.getServicesValues = mnWizardService.getServicesValues;

      this.totalRAMMegs = mnWizardService.stream.totalRAMMegs;
      this.maxRAMMegs = mnWizardService.stream.maxRAMMegs;

      this.servicesHttp = mnWizardService.stream.servicesHttp;
      this.groupHttp = mnWizardService.stream.groupHttp;
      this.initialValues = mnWizardService.initialValues;

      this.isButtonDisabled =
        mnAdminService.stream.poolsDefaultHttp
        .error
        .map(function (error) {
          return error && !_.isEmpty(error.errors);
        });

      mnWizardService.stream.groupHttp
        .loading
        .merge(mnWizardService.stream.secondGroupHttp.loading)
        .takeUntil(this.mnDestroy)
        .subscribe(this.mnAppLoding.next.bind(this.mnAppLoding));

      mnWizardService.stream.groupHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function (result) {
          mnWizardService.stream.secondGroupHttp.post({
            indexesHttp: {
              storageMode: mnWizardService.wizardForm.newClusterConfig.get("storageMode").value
            },
            authHttp: [mnWizardService.wizardForm.newCluster.value.user, false]
          });
        });

      mnWizardService.stream.secondGroupHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function () {
          mnAuthService.stream.loginHttp.post(mnWizardService.getUserCreds());
        })

      mnAuthService.stream.loginHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function () {
          if (mnWizardService.wizardForm.termsAndConditions.get("register").value) {
            mnWizardService.stream.emailHttp.response.first().subscribe();
            mnWizardService.stream.emailHttp.post([
              mnWizardService.wizardForm.termsAndConditions.get("user").value,
              mnWizardService.initialValues.implementationVersion
            ]);
          }
          uiRouter.urlRouter.sync();
        });
    }
  })();
