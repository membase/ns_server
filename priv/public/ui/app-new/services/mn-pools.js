var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnPools = (function () {
  "use strict";

  var launchID =  (new Date()).valueOf() + '-' + ((Math.random() * 65536) >> 0);

  MnPoolsService.annotations = [
    new ng.core.Injectable()
  ];

  MnPoolsService.parameters = [
    ng.common.http.HttpClient,
    mn.pipes.MnParseVersion
  ];

  MnPoolsService.prototype.get = get;

  return MnPoolsService;

  function MnPoolsService(http, mnParseVersionPipe) {
    this.http = http;
    this.stream = {};

    this.stream.getSuccess =
      (new Rx.BehaviorSubject())
      .switchMap(this.get.bind(this))
      .shareReplay(1);

    this.stream.isEnterprise =
      this.stream
      .getSuccess
      .pluck("isEnterprise");

    this.stream.implementationVersion =
      this.stream
      .getSuccess
      .pluck("implementationVersion");

    this.stream.majorMinorVersion =
      this.stream
      .implementationVersion
      .map(mnParseVersionPipe.transform.bind(mnParseVersionPipe))
      .map(function (rv) {
        return rv[0].split('.').splice(0,2).join('.');
      });
  }

  function get(mnHttpParams) {
    return this.http
      .get('/pools').map(function (pools) {
        pools.isInitialized = !!pools.pools.length;
        pools.launchID = pools.uuid + '-' + launchID;
        return pools;
      });
  }
})();
