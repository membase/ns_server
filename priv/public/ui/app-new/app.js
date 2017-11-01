var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnApp = (function () {
  "use strict";

  var MnApp =
      ng.core.Injectable()
      .Class({
        constructor: function MnAppService() {
          this.stream = {};
          this.stream.httpResponse = new Rx.Subject();
          this.stream.pageNotFound = new Rx.Subject();
          this.stream.appError = new Rx.Subject();
          this.stream.http401 =
            this.stream
            .httpResponse
            .filter(function (rv) {
              //rejection.config.url !== "/controller/changePassword"
              //$injector.get('mnLostConnectionService').getState().isActivated
              return (rv instanceof ng.common.http.HttpErrorResponse) &&
                (rv.status === 401) && !rv.headers.get("ignore-401");
            });
        }
      });

  return MnApp;

})();

(function () {
  "use strict";

  var MnHttpEncoder =
      ng.core.Class({
        extends: ng.common.http.HttpUrlEncodingCodec,
        constructor: function () {},
        encodeKey: function (k) {
          return encodeURIComponent(k);
        },
        encodeValue: function (v) {
          return encodeURIComponent(this.serializeValue(v));
        },
        serializeValue: function (v) {
          if (_.isObject(v)) {
            return _.isDate(v) ? v.toISOString() : JSON.stringify(v);
          }
          if (v === null || _.isUndefined(v)) {
            return "";
          }
          return v;
        }
      });

  var MnHttpInterceptor =
      ng.core.Injectable()
      .Class({
        constructor: [
          mn.services.MnApp,
          function MnHttpInterceptor(mnAppService) {
            this.httpClientResponse = mnAppService.stream.httpResponse;
          }],
        intercept: function (req, next) {
          var that = this;

          var mnReq = req.clone({
            setHeaders: {
              'invalid-auth-response': 'on',
              'Cache-Control': 'no-cache',
              'Pragma': 'no-cache',
              'ns-server-ui': 'yes'
            }
          });

          var params;

          if (req.method === 'POST' || req.method === 'PUT') {
            if (_.isObject(mnReq.body) && !_.isArray(mnReq.body)) {
              params = new ng.common.http.HttpParams({encoder: new MnHttpEncoder()});
              _.forEach(mnReq.body, function (v, k) {
                params = params.set(k, v);
              });
            } else {
              params = mnReq.body;
            }
            mnReq = mnReq.clone({
              body: params,
              headers: mnReq.headers.set(
                'Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8')});
          }

          return next
            .handle(mnReq)
            .do(function (event) {
              that.httpClientResponse.next(event);
            }).catch(function (event) {
              that.httpClientResponse.next(event);
              return Rx.Observable.throw(event);
            });
        }
      });

  var AppComponent =
      ng.core.Component({
        selector: "app-root",
        template: '<ui-view class="root-container"></ui-view>'
      })
      .Class({
        constructor: function AppComponent() {}
      });

  var AppModule =
      ng.core.NgModule({
        declarations: [
          AppComponent,
          ServersComponent,
          OverviewComponent,
        ],
        imports: [
          mn.modules.MnElementModule,
          mn.modules.MnPipesModule,
          mn.modules.MnAuth,
          mn.modules.MnAdmin,
          mn.modules.MnWizard,
          ng.platformBrowser.BrowserModule,
          ng.common.http.HttpClientModule,
          ngb.NgbModule.forRoot(),
          window['@uirouter/angular'].UIRouterModule.forRoot({
            states: [{
              name: 'app',
              url: '/?{enableInternalSettings:bool}&{disablePoorMansAlerts:bool}',
              component: AppComponent,
              params: {
                enableInternalSettings: {
                  value: null,
                  squash: true,
                  dynamic: true
                },
                disablePoorMansAlerts: {
                  value: null,
                  squash: true,
                  dynamic: true
                }
              },
              abstract: true
            }, {
              name: "app.auth",
              component: mn.components.MnAuth
            }, {
              name: "app.admin",
              abstract: true,
              component: mn.components.MnAdmin
            }],
            useHash: true,
            config: function uiRouterConfigFn(uiRouter, injector) {
              var mnAppService = injector.get(mn.services.MnApp);

              uiRouter.urlRouter.deferIntercept();

              uiRouter.stateService
                .defaultErrorHandler(function (error) {
                  mnAppService.stream.appError.next(error);
                });

              uiRouter.urlRouter.otherwise(function () {
                mnAppService.stream.pageNotFound.next(true);
              });
            }
          }),
        ],
        bootstrap: [window["@uirouter/angular"].UIView],
        entryComponents: [],
        providers: [
          mn.services.MnTasks,
          mn.services.MnPools,
          mn.services.MnExceptionHandler,
          mn.services.MnPermissions,
          mn.services.MnBuckets,
          mn.services.MnApp, {
            provide: ng.core.ErrorHandler,
            useClass: mn.services.MnExceptionHandler
          }, {
            provide: ng.common.http.HTTP_INTERCEPTORS,
            useClass: MnHttpInterceptor,
            multi: true
          }
        ]
      })
      .Class({
        constructor: [
          mn.services.MnExceptionHandler,
          ng.platformBrowser.Title,
          mn.services.MnApp,
          mn.services.MnAuth,
          window['@uirouter/angular'].UIRouter,
          mn.services.MnAdmin,
          function AppModule(mnExceptionHandlerService, title, mnAppService, mnAuthService, uiRouter, mnAdminService) {

            mnAppService
              .stream
              .appError
              .subscribe(function (error) {
                error && mnExceptionHandlerService.handleError(error);
              });

            mnAppService
              .stream
              .http401
              .merge(mnAuthService
                     .stream
                     .logoutResult)
              .subscribe(function () {
                uiRouter.stateService.go('app.auth', null, {location: false});
              });

            mnAppService
              .stream
              .pageNotFound
              .subscribe(function () {
                uiRouter.stateService.go('app.admin.overview');
              });

            mnAdminService
              .stream
              .prettyVersion
              .subscribe(function (version) {
                title.setTitle("Couchbase Console" + (version ? ' ' + version : ''));
              });

            uiRouter.urlRouter.listen();
            uiRouter.urlRouter.sync();
          }]
      });

  document.addEventListener('DOMContentLoaded', function () {

    ng.platformBrowserDynamic
      .platformBrowserDynamic()
      .bootstrapModule(AppModule);

  });
})();
