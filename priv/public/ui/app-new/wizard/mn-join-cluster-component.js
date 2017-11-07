var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnJoinCluster =
  (function () {
    "use strict";

    mn.helper.extends(MnJoinCluster, mn.helper.MnDestroyableComponent);

    MnJoinCluster.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/wizard/mn-join-cluster.html"
      })
    ];

    MnJoinCluster.parameters = [
      mn.services.MnWizard,
      mn.services.MnApp,
      mn.services.MnAuth,
      window['@uirouter/angular'].UIRouter
    ];

    MnJoinCluster.prototype.onSubmit = onSubmit;

    return MnJoinCluster;

    function onSubmit() {
      this.submitted = true;

      if (this.mnAppLoding.getValue()) {
        return;
      }

      this.groupHttp.clearErrors();

      if (this.joinClusterForm.invalid) {
        return;
      }

      this.groupHttp.post({
        hostnameHttp: this.wizardForm.joinCluster.get("clusterStorage.hostname").value,
        diskStorageHttp: this.wizardForm.joinCluster.get("clusterStorage.storage").value,
        querySettingsHttp: this.wizardForm.joinCluster.get("querySettings").value
      });
    }

    function MnJoinCluster(mnWizardService, mnAppService, mnAuthService, uiRouter) {
      mn.helper.MnDestroyableComponent.call(this);

      this.focusField = true;

      this.wizardForm = mnWizardService.wizardForm;

      this.mnAppLoding = mnAppService.stream.loading;

      this.joinClusterForm = mnWizardService.wizardForm.joinCluster;

      this.hostnameHttp = mnWizardService.stream.hostnameHttp;
      this.diskStorageHttp = mnWizardService.stream.diskStorageHttp;
      this.joinClusterHttp = mnWizardService.stream.joinClusterHttp;

      this.groupHttp =
        new mn.helper.MnPostGroupHttp({
          hostnameHttp: this.hostnameHttp,
          diskStorageHttp: this.diskStorageHttp,
          querySettingsHttp: mnWizardService.stream.querySettingsHttp
        })
        .addLoading()
        .addSuccess();

      this.groupHttp
        .loading
        .merge(this.joinClusterHttp.loading)
        .takeUntil(this.mnDestroy)
        .subscribe(this.mnAppLoding.next.bind(this.mnAppLoding));

      this.groupHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe((function () {
          var data = mnWizardService.wizardForm.joinCluster.get("clusterAdmin").value;
          data.services =
            mnWizardService.getServicesValues(
              mnWizardService.wizardForm.joinCluster.get("services.flag")).join(",");

          mnWizardService.stream.joinClusterHttp.post(data);
        }).bind(this));

      this.joinClusterHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function () {
          var data = mnWizardService.wizardForm.joinCluster.get("clusterAdmin").value;
          mnAuthService.stream.loginHttp.post(data);
        });

      mnAuthService.stream.loginHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function () {
          uiRouter.urlRouter.sync();
        });
    }
  })();
