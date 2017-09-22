var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnAuth = (function () {
  "use strict";

  //TODO chech that the streams do not contain privat info after logout
  var MnAuth =
      ng.core.Injectable()
      .Class({
        constructor: [
          ng.common.http.HttpClient,
          function MnAuthService(http) {
            this.http = http;
            this.stream = {};
            this.stream.doLogin = new Rx.Subject();
            this.stream.doLogout = new Rx.Subject();

            this.stream.loginResult =
              this.stream
              .doLogin
              .switchMap(this.login.bind(this))
              .share();

            this.stream.loginError =
              this.stream
              .loginResult
              .filter(function (rv) {
                return rv instanceof ng.common.http.HttpErrorResponse;
              })
              .share();

            this.stream.loginSuccess =
              this.stream
              .loginResult
              .filter(function (rv) {
                return !(rv instanceof ng.common.http.HttpErrorResponse);
              })
              .share();

            this.stream.logoutResult =
              this.stream
              .doLogout
              .switchMap(this.logout.bind(this))
              .share();

          }],
        login: login,
        logout: logout,
        whoami: whoami
      });

  return MnAuth;

  function whoami() {
    return this.http.get('/whoami');
  }

  function login(user) {
    return this.http
      .post('/uilogin', user || {}, {responseType: 'text'})
      .catch(function (err) {
        return Rx.Observable.of(err);
      });
    // should be moved into app.admin alerts
    // we should say something like you are using cached vesrion, reload the tab
    // return that.mnPoolsService
    //   .get$
    //   .map(function (cachedPools, newPools) {

    // if (cachedPools.implementationVersion !== newPools.implementationVersion) {
    //   return {ok: false, status: 410};
    // } else {
    //   return resp;
    // }
    // });
  }

  function logout() {
    return this.http.post("/uilogout", undefined, {responseType: 'text'})
      .catch(function (err) {
        return Rx.Observable.of(err);
      });
      // .do(function () {
        // $uibModalStack.dismissAll("uilogout");
        // $state.go('app.auth');
        // $window.localStorage.removeItem('mn_xdcr_regex');
        // $window.localStorage.removeItem('mn_xdcr_testKeys');
      // });
  }

})();
