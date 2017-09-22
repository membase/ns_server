var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnAuth =
  (function () {
    "use strict";

    var MnAuth =
        ng.core.Component({
          templateUrl: "app-new/auth/mn-auth.html",
        })
        .Class({
          constructor: [
            mn.services.MnAuth,
            window['@uirouter/angular'].UIRouter,
            ng.forms.FormBuilder,
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
            }],
          onSubmit: function (user) {
            this.doLogin.next(this.authForm.value);
          },
          ngOnDestroy: function () {
            this.destroy.next();
            this.destroy.complete();
          }
        });

    return MnAuth;
  })();
