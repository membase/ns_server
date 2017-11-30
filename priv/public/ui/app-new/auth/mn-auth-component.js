var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnAuth =
  (function () {
    "use strict";

    mn.helper.extends(MnAuthComponent, mn.helper.MnDestroyableComponent);

    MnAuthComponent.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/auth/mn-auth.html",
      })
    ];

    MnAuthComponent.parameters = [
      mn.services.MnAuth,
      window['@uirouter/angular'].UIRouter,
      ng.forms.FormBuilder
    ];

    MnAuthComponent.prototype.onSubmit = onSubmit;

    return MnAuthComponent;

    function MnAuthComponent(mnAuthService, uiRouter, formBuilder) {
      mn.helper.MnDestroyableComponent.call(this);

      this.focusField = true;

      this.loginHttp = mnAuthService.stream.loginHttp;
      this.logoutHttp = mnAuthService.stream.logoutHttp;

      this.loginHttp
        .success
        .takeUntil(this.mnDestroy)
        .subscribe(function () {
          uiRouter.urlRouter.sync();
        });

      this.authForm =
        formBuilder.group({
          user: ['', ng.forms.Validators.required],
          password: ['', ng.forms.Validators.required]
        });
    }

    function onSubmit(user) {
      this.loginHttp.post(this.authForm.value);
    }
  })();
