describe("mnAdminTasksService", function () {
  var $httpBackend;
  var $timeout;
  var mnAdminTasksService;
  var $browser;

  beforeEach(angular.mock.module('mnAdminTasksService'));
  beforeEach(inject(function ($injector) {
    $timeout = $injector.get('$timeout');
    $browser = $injector.get('$browser');
    $httpBackend = $injector.get('$httpBackend');
    mnAdminTasksService = $injector.get('mnAdminTasksService');
  }));

  it('should be properly initialized', function () {
    expect(mnAdminTasksService.runTasksLoop).toEqual(jasmine.any(Function));
    expect(mnAdminTasksService.stopTasksLoop).toEqual(jasmine.any(Function));
    expect(mnAdminTasksService.model).toEqual(jasmine.any(Object));
  });

  it('should breake tasks loop', function () {
    $httpBackend.expectGET('url').respond(200);
    mnAdminTasksService.runTasksLoop('url');
    mnAdminTasksService.stopTasksLoop();
    $httpBackend.verifyNoOutstandingExpectation();
    $httpBackend.verifyNoOutstandingRequest();
  });

  it('should run tasks requests loop and populate self model', function () {
    var tasksMarker = [{type: "recovery", status: "running", stopURI: "stopURI"}, {type: "rebalance", status: "notRunning"}, {type: "loadingSampleBucket", status: "running"}];
    $httpBackend.expectGET('run').respond(200, tasksMarker);
    mnAdminTasksService.runTasksLoop('run');
    $httpBackend.flush();
    $httpBackend.expectGET('run').respond(200, tasksMarker);
    mnAdminTasksService.runTasksLoop('run');
    $httpBackend.flush();

    $httpBackend.expectGET('run').respond(200, tasksMarker);
    $timeout.flush();

    expect(mnAdminTasksService.model.tasksRecovery).toEqual(tasksMarker[0]);
    expect(mnAdminTasksService.model.tasksRebalance).toEqual(tasksMarker[1]);
    expect(mnAdminTasksService.model.inRebalance).toBe(false);
    expect(mnAdminTasksService.model.inRecoveryMode).toBe(true);
    expect(mnAdminTasksService.model.isLoadingSamples).toBe(true);
    expect(mnAdminTasksService.model.stopRecoveryURI).toBe('stopURI');
  });

  it('should cancel existing requests if new one on the way', function () {
    var counter = new specRunnerHelper.Counter;
    $httpBackend.expectGET('run').respond(counter.increment.bind(counter));
    $httpBackend.expectGET('run').respond(counter.increment.bind(counter));
    mnAdminTasksService.runTasksLoop('run');
    mnAdminTasksService.runTasksLoop('run');
    $httpBackend.flush();

    expect(counter.counter).toBe(1);
  });

  it('should using recommended refresh period as loop interval timeout', function () {
    var defer = spyOn($browser, 'defer');
    var tasksMarker = [{type: "recovery", status: "running", stopURI: "stopURI", recommendedRefreshPeriod: 0.35}, {type: "rebalance", status: "notRunning"}, {type: "loadingSampleBucket", status: "running"}];
    $httpBackend.expectGET('run').respond(200, tasksMarker);
    mnAdminTasksService.runTasksLoop('run');
    $httpBackend.flush();
    expect(defer.calls.mostRecent().args).toEqual([jasmine.any(Function), 350]);
  });
});