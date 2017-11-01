var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnAdmin = (function () {
  "use strict";

  var version25 = encodeCompatVersion(2, 5);
  var version30 = encodeCompatVersion(3, 0);
  var version40 = encodeCompatVersion(4, 0);
  var version45 = encodeCompatVersion(4, 5);
  var version46 = encodeCompatVersion(4, 6);
  var version50 = encodeCompatVersion(5, 0);
  var version51 = encodeCompatVersion(5, 1);

  // counterpart of ns_heart:effective_cluster_compat_version/0
  function encodeCompatVersion(major, minor) {
    if (major < 2) {
      return 1;
    }
    return major * 0x10000 + minor;
  }

  //TODO chech that the streams do not contain privat info after logout
  var MnAdmin =
      ng.core.Injectable()
      .Class({
        constructor: [
          window['@uirouter/angular'].UIRouter,
          ng.common.http.HttpClient,
          mn.pipes.MnPrettyVersion,
          function MnAdminService(uiRouter, http, mnPrettyVersionPipe) {
            this.stream = {};
            this.http = http;
            this.stream.etag = new Rx.BehaviorSubject();
            this.stream.enableInternalSettings =
              uiRouter.globals
              .params$
              .pluck("enableInternalSettings");

            this.stream.whomi =
              (new Rx.BehaviorSubject())
              .switchMap(this.getWhoami.bind(this))
              .shareReplay(1);

            this.stream.getPoolsDefault =
              uiRouter.globals
              .success$
              .map(function (state) {
                return state.to().name === "app.admin.overview" ? 3000 : 10000;
              })
              .combineLatest(this.stream.etag)
              .switchMap(this.getPoolsDefault.bind(this))
              .shareReplay(1);

            this.stream.prettyVersion =
              this.getVersion()
              .pluck("implementationVersion")
              .map(mnPrettyVersionPipe.transform.bind(mnPrettyVersionPipe));

            this.stream.thisNode =
              this.stream
              .getPoolsDefault
              .pluck("nodes")
              .map(function (nodes) {
                return _.detect(nodes, "thisNode");
              });

            this.stream.compatVersion =
              this.stream
              .thisNode
              .map(function (thisNode) {
                var compat = thisNode.clusterCompatibility;
                return {
                  atLeast25: compat >= version25,
                  atLeast30: compat >= version30,
                  atLeast40: compat >= version40,
                  atLeast45: compat >= version45,
                  atLeast46: compat >= version46,
                  atLeast50: compat >= version50,
                  atLeast51: compat >= version51
                };
              });

          }],
        getVersion: function () {
          return this.http.get("/versions");
        },
        getPoolsDefault: function (params) {
          return this.http.get('/pools/default', {
            params: new ng.common.http.HttpParams()
              .set('waitChange', params[0])
              .set('etag', params[1] || "")
          });
        },
        getWhoami: function () {
          return this.http.get('/whoami');
        },
      });

  return MnAdmin;

})();
