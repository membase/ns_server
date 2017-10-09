var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnAdmin = (function () {
  "use strict";

  //TODO chech that the streams do not contain privat info after logout
  var MnAdmin =
      ng.core.Injectable()
      .Class({
        constructor: [
          window['@uirouter/angular'].UIRouter,
          ng.common.http.HttpClient,
          function MnAdminService(uiRouter, http) {
            this.stream = {};
            this.http = http;
            this.stream.etag = new Rx.BehaviorSubject();
            this.stream.enableInternalSettings =
              uiRouter.globals
              .params$
              .pluck("enableInternalSettings");

            this.stream.getPoolsDefault =
              uiRouter.globals
              .success$
              .map(function (state) {
                return state.to().name === "app.admin.overview" ? 3000 : 10000;
              })
              .combineLatest(this.stream.etag)
              .map(function (rv) {
                return {
                  etag: rv[1] ? rv[1] : "",
                  waitChange: rv[0]
                };
              })
              .switchMap(this.getPoolsDefault.bind(this))
              .publishReplay(1)
              .refCount();

          }],
        getPoolsDefault: function (params) {
          return this.http.get('/pools/default', {
            params: new ng.common.http.HttpParams()
              .set('waitChange', params.waitChange)
              .set('etag', params.etag)
          });
        }
      });

  return MnAdmin;

})();
