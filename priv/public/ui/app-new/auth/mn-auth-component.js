var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnAuth =
  (function () {
    "use strict";

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
    MnAuthComponent.prototype.ngOnDestroy = ngOnDestroy;

    return MnAuthComponent;

    function MnAuthComponent(mnAuthService, uiRouter, formBuilder) {
      this.focusField = true;
      this.destroy = new Rx.Subject();

      this.loginError =
        mnAuthService.stream.loginError;

      this.doLogin =
        mnAuthService.stream.doLogin;

      mnAuthService
        .stream
        .loginSuccess
        .takeUntil(this.destroy)
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
      this.doLogin.next(this.authForm.value);
    }

    function ngOnDestroy() {
      this.destroy.next();
      this.destroy.complete();
    }
  })();
