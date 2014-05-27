describe("app.service", function () {
  var $httpBackend;
  var $timeout;
  var service;

  function Counter() {}
  Counter.prototype.counter = 0;
  Counter.prototype.increment = function increment() {
    return this.counter++;
  };


  beforeEach(angular.mock.module('app.service'));
  beforeEach(inject(function ($injector) {
    $timeout = $injector.get('$timeout');
    $httpBackend = $injector.get('$httpBackend');
    service = $injector.get('app.service');
  }));

  it('should be properly initialized', function () {
    expect(service.runDefaultPoolsDetailsLoop).toEqual(jasmine.any(Function));
    expect(service.model).toEqual(jasmine.any(Object));
  });

  it('should have response type json', function () {
    var firstReq = {url: 'app/service/', params: {waitChange: 3000}};
    var emptyResp = '';
    var headers = {"Accept":"application/json, text/plain, */*","invalid-auth-response":"on","Cache-Control":"no-cache","Pragma":"no-cache"};

    $httpBackend.expectGET('app/service/?waitChange=3000', headers).respond(emptyResp);
    service.runDefaultPoolsDetailsLoop(firstReq);
    $httpBackend.flush();
  });

  it('should break loop if response empty', function () {
    var firstReq = {url: 'app/service/', params: {waitChange: 3000}};
    var emptyResp = '';

    $httpBackend.expectGET('app/service/?waitChange=3000').respond(emptyResp);
    service.runDefaultPoolsDetailsLoop(firstReq);
    $httpBackend.flush();
    expect(service.model.isEnterprise).toBe(undefined);
    expect(service.model.details).toBe(undefined);
  });

  it('should running loop if response exist', function () {
    var firstReq = {url: 'app/service/', params: {waitChange: 3000}};
    var fullResp = {etag: 'etag', isEnterprise: 'yep', details: {}};
    var emptyResp = '';

    $httpBackend.expectGET('app/service/?waitChange=3000').respond(fullResp);
    $httpBackend.expectGET('app/service/?etag=etag&waitChange=3000').respond(emptyResp);
    service.runDefaultPoolsDetailsLoop(firstReq);
    $httpBackend.flush();
    expect(service.model.isEnterprise).toBe(fullResp.isEnterprise);
    expect(service.model.details).toEqual(fullResp);
  });

  it('should resend request if someone already pending', function () {
    var firstReq = {url: 'app/service/', params: {waitChange: 3000}};
    var counter = new Counter;

    $httpBackend.expectGET('app/service/?waitChange=3000').respond(counter.increment.bind(counter));
    $httpBackend.expectGET('app/service/?waitChange=3000').respond(counter.increment.bind(counter));
    $httpBackend.expectGET('app/service/?waitChange=3000').respond(counter.increment.bind(counter));

    service.runDefaultPoolsDetailsLoop(firstReq);
    service.runDefaultPoolsDetailsLoop(firstReq);
    service.runDefaultPoolsDetailsLoop(firstReq);

    $httpBackend.flush();
    expect(counter.counter).toBe(1);
  });

  it('should break loop if time is out', function () {
    var firstReq = {url: 'app/service/', params: {waitChange: 3000}};
    var fullResp = {etag: 'etag', isEnterprise: 'yep', details: {}};
    var counter = new Counter;

    $httpBackend.expectGET('app/service/?etag=etag&waitChange=3000').respond(counter.increment.bind(counter));
    service.runDefaultPoolsDetailsLoop(firstReq, fullResp);
    $timeout.flush();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    expect(counter.counter).toBe(0);
  });
});