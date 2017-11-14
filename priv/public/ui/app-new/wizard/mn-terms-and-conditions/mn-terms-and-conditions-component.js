var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnTermsAndConditions =
  (function () {
    "use strict";

    MnTermsAndConditions.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/wizard/mn-terms-and-conditions/mn-terms-and-conditions.html"
      })
    ];

    MnTermsAndConditions.parameters = [
      mn.services.MnWizard,
      mn.services.MnPools,
      mn.services.MnAuth,
      window['@uirouter/angular'].UIRouter
    ];

    MnTermsAndConditions.prototype.onSubmit = onSubmit;
    MnTermsAndConditions.prototype.registerChange = registerChange;

    return MnTermsAndConditions;

    function MnTermsAndConditions(mnWizardService, mnPoolsService, mnAuthService, uiRouter) {
      this.focusField = true;

      this.uiRouter = uiRouter;
      this.isEnterprise = mnPoolsService.stream.isEnterprise;

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
    }

    function registerChange() {
      this.termsForm.get("user")[this.termsForm.get('register').value ? "enable" : "disable"]();
    }

    function onSubmit(user) {
      this.submitted = true;
      var error = this.termsForm.get("agree").value ? null : {required: true};
      this.termsForm.get("agree").setErrors(error);

      if (this.termsForm.invalid) {
        return;
      }

      this.uiRouter.stateService.go('app.wizard.newClusterConfig', null, {location: false});
    }
  })();
