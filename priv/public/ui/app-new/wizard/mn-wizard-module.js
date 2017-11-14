var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnWizard =
  (function () {
    "use strict";

    MnWizardComponent.annotations = [
      new ng.core.Component({
        templateUrl: 'app-new/wizard/mn-wizard.html'
      })
    ];

    function MnWizardComponent() {
    }

    MnWizardModule.annotations = [
      new ng.core.NgModule({
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
        ],
        providers: [
        ]
      })
    ];

    return MnWizardModule;

    function MnWizardModule() {
    }
  })();
