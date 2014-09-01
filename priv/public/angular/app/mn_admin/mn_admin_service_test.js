describe("mnAdminService", function () {
  var $httpBackend;
  var $timeout;
  var mnAdminService;
  var mnAuthService;
  var $state;

  beforeEach(angular.mock.module('mnAdminService'));
  beforeEach(inject(function ($injector) {
    $timeout = $injector.get('$timeout');
    $state = $injector.get('$state');
    $httpBackend = $injector.get('$httpBackend');
    mnAdminService = $injector.get('mnAdminService');
    mnAuthService = $injector.get('mnAuthService');

    $state.current.name = 'admin.overview';
    mnAuthService.model.defaultPoolUri = 'defaultPoolUri';
    mnAuthService.model.isAuth = true;
  }));

  it('should be properly initialized', function () {
    expect(mnAdminService.runDefaultPoolsDetailsLoop).toEqual(jasmine.any(Function));
    expect(mnAdminService.stopDefaultPoolsDetailsLoop).toEqual(jasmine.any(Function));
    expect(mnAdminService.waitChangeOfPoolsDetailsLoop).toEqual(jasmine.any(Function));
    expect(mnAdminService.model).toEqual(jasmine.any(Object));
  });

  it('should have response type json', function () {
    $httpBackend.expectGET('defaultPoolUri?waitChange=3000', {"Accept":"application/json, text/plain, */*"}).respond(200);
    mnAdminService.runDefaultPoolsDetailsLoop();
    $httpBackend.flush();
  });

  it('shouldn\'t run loop', function () {
    mnAuthService.model.defaultPoolUri = undefined;
    mnAuthService.model.isAuth = false;
    mnAdminService.runDefaultPoolsDetailsLoop();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();
  });

  it('should break loop if response empty', function () {
    $httpBackend.expectGET('defaultPoolUri?waitChange=3000').respond(200, undefined);
    mnAdminService.runDefaultPoolsDetailsLoop();
    $httpBackend.flush();
    expect(mnAdminService.model.isEnterprise).toBe(undefined);
    expect(mnAdminService.model.details).toBe(undefined);
  });

  it('should running loop if response exist', function () {
    var respond = {etag: 'etag', isEnterprise: true, details: {}};

    $httpBackend.expectGET('defaultPoolUri?waitChange=3000').respond(200, respond);
    $httpBackend.expectGET('defaultPoolUri?etag=etag&waitChange=3000').respond(200, '');
    mnAdminService.runDefaultPoolsDetailsLoop();
    $httpBackend.flush();
    expect(mnAdminService.model.isEnterprise).toBe(true);
    expect(mnAdminService.model.details).toEqual(respond);
  });

  it('should resend request if someone already pending', function () {
    var counter = new specRunnerHelper.Counter;

    $httpBackend.expectGET('defaultPoolUri?waitChange=3000').respond(counter.increment.bind(counter));
    $httpBackend.expectGET('defaultPoolUri?waitChange=3000').respond(counter.increment.bind(counter));
    $httpBackend.expectGET('defaultPoolUri?waitChange=3000').respond(counter.increment.bind(counter));

    mnAdminService.runDefaultPoolsDetailsLoop();
    mnAdminService.runDefaultPoolsDetailsLoop();
    mnAdminService.runDefaultPoolsDetailsLoop();

    $httpBackend.flush();
    expect(counter.counter).toBe(1);
  });

  it('should break loop if time is out', function () {
    var respond = {etag: 'etag', isEnterprise: 'yep', details: {}};
    var counter = new specRunnerHelper.Counter;

    $httpBackend.expectGET('defaultPoolUri?etag=etag&waitChange=3000').respond(counter.increment.bind(counter));
    mnAdminService.runDefaultPoolsDetailsLoop(respond);
    $timeout.flush();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    expect(counter.counter).toBe(0);
  });
});