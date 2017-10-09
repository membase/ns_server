var mn = mn || {};
mn.components = mn.components || {};
mn.components.MnAdmin =
  (function () {
    "use strict";

    var MnAdmin =
        ng.core.Component({
          templateUrl: "app-new/admin/mn-admin.html",
        })
        .Class({
          constructor: [
            mn.services.MnAuth,
            mn.services.MnAdmin,
            mn.services.MnPools,
            mn.services.MnPermissions,
            mn.services.MnTasks,
            function MnAdminComponent(mnAuthService, mnAdminService, mnPoolsService, mnPermissionsService, mnTasksService) {
              this.doLogout = mnAuthService.stream.doLogout;
              this.destroy = new Rx.Subject();
              this.isProgressBarClosed = new Rx.BehaviorSubject(true);
              this.mnAdminService = mnAdminService;

              this.majorMinorVersion = mnPoolsService.stream.majorMinorVersion;
              this.getPoolsSuccess = mnPoolsService.stream.getSuccess;
              this.getPoolsDefaultSuccess = mnAdminService.stream.getPoolsDefaultSuccess;
              this.tasksToDisplay = mnTasksService.stream.tasksToDisplay;

              this.tasksReadPermission =
                mnPermissionsService
                .stream
                .getSuccess
                .pluck("cluster.tasks!read")
                .distinctUntilChanged();

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

              this.mnAdminService
                .stream
                .getPoolsDefault
                .takeUntil(this.destroy)
                .subscribe(function (rv) {
                  mnAdminService.stream.etag.next(rv.etag);
                });
            }],
          ngOnDestroy: function () {
            this.destroy.next();
            this.destroy.complete();
            this.mnAdminService.stream.etag.next();
          },
          onLogout: function () {
            this.doLogout.next(true);
          },
          runInternalSettingsDialog: function () {

          },
          toggleProgressBar: function () {
            this.isProgressBarClosed.next(!this.isProgressBarClosed.getValue());
          }
        });

    return MnAdmin;
  })();


var mn = mn || {};
mn.modules = mn.modules || {};
mn.modules.MnAdmin =
  (function () {
    "use strict";

    var MnAdmin =
        ng.core.NgModule({
          declarations: [
            mn.components.MnAdmin,
          ],
          imports: [
            mn.modules.MnPipesModule,
            ng.platformBrowser.BrowserModule,
          ],
          providers: [
            mn.services.MnAdmin
          ]
        })
        .Class({
          constructor: function MnAdminModule() {}
        });

    return MnAdmin;
  })();
