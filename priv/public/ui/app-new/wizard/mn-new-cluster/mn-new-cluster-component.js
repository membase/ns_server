var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnNewCluster =
  (function () {
    "use strict";

    MnNewClusterComponent.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/wizard/mn-new-cluster/mn-new-cluster.html"
      })
    ];

    MnNewClusterComponent.parameters = [
      mn.services.MnWizard,
      window['@uirouter/angular'].UIRouter
    ];

    MnNewClusterComponent.prototype.onSubmit = onSubmit;

    return MnNewClusterComponent;

    function MnNewClusterComponent(mnWizardService, uiRouter) {
      this.focusField = true;

      this.authHttp = mnWizardService.stream.authHttp;
      this.newClusterForm = mnWizardService.wizardForm.newCluster;
      this.newClusterForm.setValidators([mn.helper.validateEqual("user.password",
                                                                 "user.passwordVerify",
                                                                 "passwordMismatch")]);

      this.authHttp
        .success
        .first()
        .subscribe(onSuccess.bind(this));

      function onSuccess() {
        uiRouter.stateService.go('app.wizard.termsAndConditions', null, {location: false});
      }
    }

    function onSubmit() {
      this.submitted = true;

      if (this.newClusterForm.invalid) {
        return;
      }

      this.authHttp.post([this.newClusterForm.value.user, true]);
    }
  })();
