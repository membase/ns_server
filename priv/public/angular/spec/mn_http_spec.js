describe('mnHttp', function () {
  var callback;

  beforeEach(function () {
    module('mnPendingQueryKeeper');
    module('mnHttp');
    callback = jasmine.createSpy('callback');
  });

  it('should have the right methods', inject(function (mnHttp) {
    var methods = ['get', 'delete', 'head', 'jsonp', 'post', 'put'];
    angular.forEach(methods, function (method) {
      expect(mnHttp[method]).toEqual(jasmine.any(Function));
    });
    expect(mnHttp).toEqual(jasmine.any(Function));
  }));

  it('should pass correct configuration into $http', function () {
    //in this test we check that:
    //1. short method merges configuration correctly
    //2. 'httpConfig' property reaches $http.
    //3. canceler ('timeout') is added to each type of request
    //4. if data has type string it shouldn't be serialized
    //5. if isNotForm is true then application/x-www-form-urlencoded header should not be passed into http
    //6. mnHttp property does not reach $http
    //7. configuration remained intact for mnPendingQueryKeeper.push
    var fakePromise = {
      then: function () {}
    };
    var $http = jasmine.createSpy('$http').and.callFake(function () {
      return fakePromise
    });

    module(function ($provide) {
      $provide.value('$http', $http);
    });

    inject(function (mnHttp, $q, mnPendingQueryKeeper) {
      spyOn(mnPendingQueryKeeper, "push");
      mnHttp.get("/url", {
        httpConfig: "httpConfig",
        mnHttp: {
          deleteMe: true
        }
      });
      expect($http).toHaveBeenCalledWith({
        httpConfig: 'httpConfig',
        method: 'get',
        url: '/url',
        timeout: $q.defer().promise
      });
      expect(mnPendingQueryKeeper.push).toHaveBeenCalledWith({
        config: {
          httpConfig: 'httpConfig',
          mnHttp: {
            deleteMe: true
          },
          method: 'get',
          url: '/url'
        },
        canceler: jasmine.any(Function),
        httpPromise: fakePromise
      });
      mnHttp.post("/url", {
        data: "data"
      }, {
        httpConfig: "httpConfig",
        mnHttp: {
          deleteMe: true
        }
      });
      expect($http).toHaveBeenCalledWith({
        httpConfig: 'httpConfig',
        method: 'post',
        url: '/url',
        data: 'data=data',
        headers: {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
        timeout: $q.defer().promise
      });
      mnHttp.put("/url", "doNotSerializeMe", {
        httpConfig: "httpConfig",
        mnHttp: {
          isNotForm: true
        }
      });
      expect($http).toHaveBeenCalledWith({
        httpConfig: 'httpConfig',
        method: 'put',
        url: '/url',
        headers: {},
        data: 'doNotSerializeMe',
        timeout: $q.defer().promise
      });
    });
  });

  it("should cancel previous post request in case new with same configuration and flag cancelPrevious is coming", inject(function (mnHttp, $httpBackend, $rootScope, mnPendingQueryKeeper) {
    $httpBackend.expect('POST', '/url').respond(200);
    $httpBackend.expect('POST', '/url').respond(200);

    spyOn(mnPendingQueryKeeper, "getQueryInFly").and.callThrough();
    mnHttp.post("/url", undefined, {mnHttp: {cancelPrevious: true}}).catch(function (response) {
      expect(response.status).toBe(0);
      callback();
    });
    mnHttp.post("/url", undefined, {mnHttp: {cancelPrevious: true}});
    $httpBackend.flush();

    expect(mnPendingQueryKeeper.getQueryInFly.calls.count()).toBe(2);
    expect(callback).toHaveBeenCalled();
    $httpBackend.verifyNoOutstandingExpectation();
    $httpBackend.verifyNoOutstandingRequest();
  }));

  it("should cancel request by timeout in case timeout was passed", inject(function (mnHttp, $httpBackend, $timeout) {
    $httpBackend.expect('GET', '/url').respond(200);
    mnHttp.get("/url", {timeout: 10000}).catch(function (response) {
      expect(response.status).toBe(0);
      callback();
    });

    $timeout.flush(10000);

    expect(callback).toHaveBeenCalled();
    $httpBackend.verifyNoOutstandingExpectation();
    $httpBackend.verifyNoOutstandingRequest();
  }));

  it("should be cleared properly", inject(function (mnHttp, $timeout, $httpBackend, mnPendingQueryKeeper) {
    //in this test we check that protective logic (isCleared) works correctly in case we cancel previous query
    //without protective logic timeout.cancel and removeQueryInFly will be called 3 times
    spyOn(mnPendingQueryKeeper, "removeQueryInFly").and.callThrough();
    $httpBackend.expect('POST', '/url').respond(200);
    $httpBackend.expect('POST', '/url').respond(200);

    spyOn($timeout, "cancel").and.callThrough();
    mnHttp.post("/url", undefined, {timeout: 10000, mnHttp: {cancelPrevious: true}});
    mnHttp.post("/url", undefined, {timeout: 10000, mnHttp: {cancelPrevious: true}});
    $httpBackend.flush();

    expect($timeout.cancel.calls.count()).toBe(2);
    expect(mnPendingQueryKeeper.removeQueryInFly.calls.count()).toBe(2);

    $httpBackend.verifyNoOutstandingExpectation();
    $httpBackend.verifyNoOutstandingRequest();
  }));

});
