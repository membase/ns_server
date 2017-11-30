var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnTermsAndConditions =
  (function () {
    "use strict";

    mn.helper.extends(MnTermsAndConditions, mn.helper.MnDestroyableComponent);

    MnTermsAndConditions.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/wizard/mn-terms-and-conditions.html"
      })
    ];

    MnTermsAndConditions.parameters = [
      mn.services.MnWizard,
      mn.services.MnPools,
      mn.services.MnApp,
      mn.services.MnAuth,
      window['@uirouter/angular'].UIRouter
    ];

    MnTermsAndConditions.prototype.onSubmit = onSubmit;
    MnTermsAndConditions.prototype.registerChange = registerChange;
    MnTermsAndConditions.prototype.validateAgreeFlag = validateAgreeFlag;
    MnTermsAndConditions.prototype.finishWithDefaut = finishWithDefaut;

    return MnTermsAndConditions;

    function MnTermsAndConditions(mnWizardService, mnPoolsService, mnAppService, mnAuthService, uiRouter) {
      mn.helper.MnDestroyableComponent.call(this);

      this.focusField = true;

      this.uiRouter = uiRouter;
      this.isEnterprise = mnPoolsService.stream.isEnterprise;
      this.wizardForm = mnWizardService.wizardForm;
      this.initialValues = mnWizardService.initialValues;

      this.license =
        mnPoolsService
        .stream
        .isEnterprise
        .switchMap(function (isEnterprise) {
          return isEnterprise ?
            mnWizardService.getEELicense() :
            mnWizardService.getCELicense();
        });

      this.termsHref =
        mnPoolsService
        .stream
        .isEnterprise
        .map(function (isEnterprise) {
          return isEnterprise ?
            'https://www.couchbase.com/ESLA05242016' :
            'https://www.couchbase.com/community';
        });

      this.termsForm = mnWizardService.wizardForm.termsAndConditions;
      this.termsForm.get("agree").setValue(false);

      this.registerChange();
      this.groupHttp = mnWizardService.stream.groupHttp;
      this.mnAppLoding = mnAppService.stream.loading;

      this.groupHttp
        .loading
        .merge(mnWizardService.stream.secondGroupHttp.loading)
        .takeUntil(this.mnDestroy)
        .subscribe(this.mnAppLoding.next.bind(this.mnAppLoding));

      this.groupHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function (result) {
          mnWizardService.stream.secondGroupHttp.post({
            indexesHttp: {
              storageMode: mnWizardService.initialValues.storageMode
            },
            authHttp: [mnWizardService.wizardForm.newCluster.value.user, false]
          });
        });

      mnWizardService.stream.secondGroupHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function () {
          mnAuthService.stream.loginHttp.post(mnWizardService.getUserCreds());
        });

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

    function validateAgreeFlag() {
      var error = this.termsForm.get("agree").value ? null : {required: true};
      this.termsForm.get("agree").setErrors(error);
    }

    function finishWithDefaut() {
      this.submitted = true;

      if (this.mnAppLoding.getValue()) {
        return;
      }

      this.validateAgreeFlag();
      this.groupHttp.clearErrors();

      if (this.termsForm.invalid) {
        return;
      }

      this.groupHttp.post({
        poolsDefaultHttp: [{
          clusterName: this.wizardForm.newCluster.get("clusterName").value
        }, false],
        servicesHttp: {
          services: 'kv,index,fts,n1ql,eventing',
          setDefaultMemQuotas : true
        },
        diskStorageHttp: this.initialValues.clusterStorage,
        hostnameHttp: this.initialValues.hostname,
        statsHttp: true
      });
    }

    function registerChange() {
      this.termsForm.get("user")[this.termsForm.get('register').value ? "enable" : "disable"]();
    }

    function onSubmit(user) {
      this.submitted = true;
      this.validateAgreeFlag();

      if (this.termsForm.invalid) {
        return;
      }

      this.uiRouter.stateService.go('app.wizard.newClusterConfig', null, {location: false});
    }
  })();
