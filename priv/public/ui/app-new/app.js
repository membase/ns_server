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
      constructor: function MnHttpInterceptor() {},
      intercept: function (req, next) {

        var mnReq = req.clone({setHeaders: {
          'invalid-auth-response': 'on',
          'Cache-Control': 'no-cache',
          'Pragma': 'no-cache',
          'ns-server-ui': 'yes'
        }});

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

        return next.handle(mnReq);
      }
    });

  var AppModule =
      ng.core.NgModule({
        declarations: [],
        imports: [
          ng.platformBrowser.BrowserModule,
          window['@uirouter/angular'].UIRouterModule
        ],
        bootstrap: [],
        entryComponents: [],
        providers: [
          {provide: ng.common.http.HTTP_INTERCEPTORS, useClass: MnHttpInterceptor, multi: true}
        ]
      })
      .Class({
        constructor: function AppModule() {},
        ngDoBootstrap: function () {}
      });

  document.addEventListener('DOMContentLoaded', function () {
    ng.platformBrowserDynamic
      .platformBrowserDynamic()
      .bootstrapModule(AppModule);
  });
})();
