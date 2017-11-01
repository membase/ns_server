var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnWizard =
  (function () {
    "use strict";

    var MnWizardComponent = ng.core.Component({
      templateUrl: 'app-new/wizard/mn-wizard.html'
    }).Class({
      constructor: function MnWizardComponent() {}
    });

    var MnWizard =
        ng.core.NgModule({
          declarations: [
            MnWizardComponent,
            mn.components.MnWelcome
          ],
          imports: [
            ng.platformBrowser.BrowserModule,
            mn.modules.MnShared,
            window['@uirouter/angular'].UIRouterModule.forChild({
              states: [{
                name: "app.wizard",
                component: MnWizardComponent,
                abstract: true
              }, {
                name: "app.wizard.welcome",
                component: mn.components.MnWelcome
              }]
            })
          ]
        })
        .Class({
          constructor: function MnWizardModule() {},
        });

    return MnWizard;
  })();
