var mn = mn || {};
mn.helper = mn.helper || {};
mn.helper.extends = (function () {

  var extendStatics = Object.setPrototypeOf ||
    ({ __proto__: [] } instanceof Array && function (d, b) { d.__proto__ = b; }) ||
    function (d, b) { for (var p in b) if (b.hasOwnProperty(p)) d[p] = b[p]; };

  function __extends(d, b) {
    extendStatics(d, b);
    function __() { this.constructor = d; }
    d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
  }

  return __extends;
})();

var mn = mn || {};
mn.helper = mn.helper || {};
mn.helper.validateEqual = (function () {
  return function (key1, key2, erroName) {
    return function (group) {
      if (group.get(key1).value !== group.get(key2).value) {
        var rv = {};
        rv[erroName] = true;
        return rv;
      }
    }
  }
})();

var mn = mn || {};
mn.helper = mn.helper || {};
mn.helper.httpErrorScenario = (function () {
  return function (obs) {
    return obs
      .filter(function (rv) {
        return (rv instanceof ng.common.http.HttpErrorResponse)
      })
      .pluck("error")
      .map(JSON.parse)
      .share();
  }
})();

var mn = mn || {};
mn.helper = mn.helper || {};
mn.helper.httpSuccessScenario = (function () {
  return function (obs) {
    return obs
      .filter(function (rv) {
        return !(rv instanceof ng.common.http.HttpErrorResponse);
      })
      .share();
  }
})();


mn.helper.MnPostHttp = (function () {

  MnPostHttp.prototype.addResponse = addResponse;
  MnPostHttp.prototype.addSuccess = addSuccess;
  MnPostHttp.prototype.addError = addError;
  MnPostHttp.prototype.post = post;
  MnPostHttp.prototype.clearError = clearError;

  return MnPostHttp;

  function MnPostHttp(call) {
    this._dataSubject = new Rx.Subject();
    this._errorSubject = new Rx.Subject();
    this.addResponse(call);
  }

  function clearError() {
    this._errorSubject.next(null);
  }

  function addResponse(call) {
    this.response = this._dataSubject.switchMap(call).share();
    return this;
  }

  function addError(modify) {
    var error = this.response.let(mn.helper.httpErrorScenario).merge(this._errorSubject);
    if (modify) {
      error = error.let(modify);
    }
    this.error = error;
    return this;
  }

  function addSuccess(modify) {
    var success = this.response.let(mn.helper.httpSuccessScenario);
    if (modify) {
      success = success.let(modify);
    }
    this.success = success;
    return this;
  }

  function post(data) {
    this._dataSubject.next(data);
  }
})();

mn.helper.IEC = {
  Ki: 1024,
  Mi: 1048576,
  Gi: 1073741824
};
