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

    MnWizardComponent.parameters = [
      mn.services.MnWizard,
      mn.services.MnPools,
      mn.services.MnAdmin
    ];

    function MnWizardComponent(mnWizardService, mnPoolsService, mnAdminService) {
      var newClusterConfig =
          mnWizardService
          .wizardForm
          .newClusterConfig;

      mnAdminService
        .stream
        .implementationVersion
        .first()
        .subscribe(function (implementationVersion) {
          mnWizardService.initialValues.implementationVersion = implementationVersion;
        });

      mnWizardService
        .stream
        .getSelfConfig
        .first()
        .subscribe(function (selfConfig) {
          var hostname = selfConfig['otpNode'].split('@')[1] || '127.0.0.1';
          newClusterConfig.get("clusterStorage.hostname").setValue(hostname);
          newClusterConfig.get("services.field.kv").setValue(selfConfig.memoryQuota);
          newClusterConfig.get("services.field.index").setValue(selfConfig.indexMemoryQuota);
          newClusterConfig.get("services.field.fts").setValue(selfConfig.ftsMemoryQuota);
          mnWizardService
            .wizardForm
            .joinCluster
            .get("clusterStorage.hostname")
            .setValue(hostname);

          mnWizardService.initialValues.hostname = hostname;
        });

      mnPoolsService
        .stream
        .isEnterprise
        .subscribe(function (isEnterprise) {
          var storageMode = isEnterprise ? "plasma" : "forestdb";
          newClusterConfig.get("storageMode").setValue(storageMode);

          mnWizardService.initialValues.storageMode = storageMode;
        });

      mnWizardService
        .stream
        .initHddStorage
        .first()
        .subscribe(function (initHdd) {
          newClusterConfig.get("clusterStorage.storage").patchValue(initHdd);
          mnWizardService
            .wizardForm
            .joinCluster
            .get("clusterStorage.storage")
            .patchValue(initHdd);

          mnWizardService.initialValues.clusterStorage = initHdd;
        });
    }

    MnWizardModule.annotations = [
      new ng.core.NgModule({
        declarations: [
          MnWizardComponent,
          mn.components.MnNewCluster,
          mn.components.MnNewClusterConfig,
          mn.components.MnTermsAndConditions,
          mn.components.MnWelcome,
          mn.components.MnNodeStorageConfig,
          mn.components.MnServicesConfig,
          mn.components.MnStorageMode
        ],
        imports: [
          ng.platformBrowser.BrowserModule,
          ng.forms.ReactiveFormsModule,
          mn.modules.MnShared,
          mn.modules.MnPipesModule,
          ng.common.http.HttpClientJsonpModule,
          window['@uirouter/angular'].UIRouterModule.forChild({
            states: [{
              name: "app.wizard",
              component: MnWizardComponent,
              abstract: true
            }, {
              name: "app.wizard.welcome",
              component: mn.components.MnWelcome
            }, {
              name: "app.wizard.newCluster",
              component: mn.components.MnNewCluster
            }, {
              name: "app.wizard.termsAndConditions",
              component: mn.components.MnTermsAndConditions
            }, {
              name: "app.wizard.newClusterConfig",
              component: mn.components.MnNewClusterConfig
            }]
          })
        ],
        providers: [
          mn.services.MnWizard
        ]
      })
    ];

    return MnWizardModule;

    function MnWizardModule() {
    }
  })();
