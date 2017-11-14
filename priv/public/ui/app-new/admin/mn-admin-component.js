var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnAdmin =
  (function () {
    "use strict";

    MnAdminComponent.annotations = [
      new ng.core.Component({
        templateUrl: "app-new/admin/mn-admin.html",
        animations: [
          ng.animations.trigger(
            'mnMinimize', [
              ng.animations.state(
                ':enter',
                ng.animations.style({opacity: '0', height: '0'}),
                // ng.animations.animation('500ms',
                //                         ng.animations.style({opacity: '1', height: '2rem'}))
              ),
              ng.animations.state(
                ':leave',
                ng.animations.style({opacity: '1', height: '2rem'}),
                ng.animations.animation('500ms',
                                        ng.animations.style({opacity: '0', height: '0'}))
              )
            ]
          )
        ]
      })
    ];

    MnAdminComponent.parameters = [
      mn.services.MnAuth,
      mn.services.MnAdmin,
      mn.services.MnPools,
      mn.services.MnPermissions,
      mn.services.MnTasks,
      window['@uirouter/angular'].UIRouter
    ];

    MnAdminComponent.prototype.ngOnDestroy = ngOnDestroy;
    MnAdminComponent.prototype.onLogout = onLogout;
    MnAdminComponent.prototype.runInternalSettingsDialog = runInternalSettingsDialog;
    MnAdminComponent.prototype.showResetPasswordDialog = showResetPasswordDialog;
    MnAdminComponent.prototype.toggleProgressBar = toggleProgressBar;

    return MnAdminComponent;

    function MnAdminComponent(mnAuthService, mnAdminService,
                              mnPoolsService,
                              mnPermissionsService,
                              mnTasksService,
                              uiRouter
                             ) {
      this.doLogout = mnAuthService.stream.doLogout;
      this.destroy = new Rx.Subject();
      this.isProgressBarClosed = new Rx.BehaviorSubject(true);
      this.mnAdminService = mnAdminService;
      this.showRespMenu = false;

      this.majorMinorVersion = mnPoolsService.stream.majorMinorVersion;
      this.tasksToDisplay = mnTasksService.stream.tasksToDisplay;
      this.isEnterprise = mnPoolsService.stream.isEnterprise;
      this.whomiId = mnAdminService.stream.whomi.pluck("id");

      this.stateService = uiRouter.stateService;

      mnAdminService
        .stream
        .getPoolsDefault
        .takeUntil(this.destroy)
        .subscribe(function (rv) {
          mnAdminService.stream.etag.next(rv.etag);
        }, function (rv) {
          if ((rv instanceof ng.common.http.HttpErrorResponse) && (rv.status === 404)) {
            uiRouter.stateService.go('app.wizard.welcome', null, {location: false});
          }
        });

      this.isAdminRootReady =
        mnAdminService
        .stream
        .getPoolsDefault
        .map(Boolean);

      this.clusterName =
        mnAdminService
        .stream
        .getPoolsDefault
        .pluck("clusterName");

      this.tasksReadPermission =
        mnPermissionsService
        .stream
        .getSuccess
        .pluck("cluster.tasks!read")
        .distinctUntilChanged();

      this.enableResetButton =
        Rx.Observable.combineLatest(
          mnPoolsService.stream.isEnterprise,
          mnAdminService.stream.compatVersion.pluck("atLeast50"),
          mnAdminService.stream.whomi.map(function (my) {
            return my.domain === 'local' || my.domain === 'admin';
          })
        )
        .map(_.curry(_.every)(_, Boolean));

      this.enableInternalSettings =
        mnAdminService
        .stream
        .enableInternalSettings
        .combineLatest(mnPermissionsService
                       .stream
                       .getSuccess
                       .pluck("cluster.admin.settings!write"))
        .map(_.curry(_.every)(_, Boolean));

      this.tasksReadPermission
        .switchMap(function (canRead) {
          return canRead ?
            mnTasksService.stream.extractNextInterval :
            Rx.Observable.never();
        })
        .takeUntil(this.destroy)
        .subscribe(function (interval) {
          mnTasksService.stream.interval.next(interval);
        });
    }

    function ngOnDestroy() {
      this.destroy.next();
      this.destroy.complete();
      this.mnAdminService.stream.etag.next();
    }

    function onLogout() {
      this.doLogout.next(true);
    }

    function runInternalSettingsDialog() {

    }

    function showResetPasswordDialog() {

    }

    function toggleProgressBar() {
      this.isProgressBarClosed.next(!this.isProgressBarClosed.getValue());
    }
  })();


var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnAdmin =
  (function () {
    "use strict";

    OverviewComponent.annotations = [
      new ng.core.Component({
        template: 'overview'
      })
    ];
    function OverviewComponent() {
    }

    ServersComponent.annotations = [
      new ng.core.Component({
        template: '<mn-element-cargo depot="alerts">asdasdasdas</mn-element-cargo>'
      })
    ];
    function ServersComponent() {
    }

    MnAdminModule.annotations = [
        new ng.core.NgModule({
          declarations: [
            mn.directives.MnDraggable,
            mn.components.MnAdmin,
            OverviewComponent,
            ServersComponent
          ],
          imports: [
            window['@uirouter/angular'].UIRouterModule.forChild({
              states: [{
                name: "app.admin.overview",
                url: "overview",
                views: {
                  "main@app.admin": OverviewComponent
                },
                data: {
                  title: "Dashboard"
                }
              }, {
                name: "app.admin.servers",
                url: "servers",
                views: {
                  "main@app.admin": ServersComponent
                },
                data: {
                  title: "Servers"
                }
              }]
            }),
            mn.modules.MnElementModule,
            mn.modules.MnPipesModule,
            ng.platformBrowser.BrowserModule,
            ngb.NgbModule,
            ng.platformBrowser.animations.BrowserAnimationsModule
          ],
          providers: [
            mn.services.MnAdmin
          ]
        })
    ];

    return MnAdminModule;

    function MnAdminModule() {
    }
  })();
