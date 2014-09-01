describe("mnAdminOverviewService", function () {
  var $httpBackend;
  var $browser;
  var $timeout;
  var mnAdminOverviewService;

  beforeEach(angular.mock.module('mnAdminOverviewService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    $browser = $injector.get('$browser');
    $timeout = $injector.get('$timeout');
    mnAdminOverviewService = $injector.get('mnAdminOverviewService');

    spyOn($browser, 'defer').and.callThrough();
  }));

  it('should be properly initialized', function () {
    expect(mnAdminOverviewService.model).toEqual(jasmine.any(Object));
    expect(mnAdminOverviewService.clearStatsTimeout).toEqual(jasmine.any(Function));
    expect(mnAdminOverviewService.runStatsLoop).toEqual(jasmine.any(Function));
  });

  it('should cancel existing requests if new one on the way', function () {
    var respond = {timestamp: [1411376448000,1411376452000,1411376456000,1411376460000,1411376464000,1411376468000]};
    $httpBackend.expectGET('/pools/default/overviewStats').respond(200, respond);
    mnAdminOverviewService.runStatsLoop();
    $httpBackend.flush();
    $httpBackend.expectGET('/pools/default/overviewStats').respond(200, respond);
    mnAdminOverviewService.runStatsLoop();
    $httpBackend.flush();

    $httpBackend.expectGET('/pools/default/overviewStats').respond(200, respond);
    $timeout.flush();
  });

  it('should properly send requests and populate self model', function () {
    var respond = {timestamp: [1411376448000,1411376452000,1411376456000,1411376460000,1411376464000,1411376468000]};
    $httpBackend.expectGET('/pools/default/overviewStats').respond(200, respond);
    mnAdminOverviewService.runStatsLoop();
    $httpBackend.flush();

    expect(mnAdminOverviewService.model.stats).toEqual(respond);
    expect($browser.defer.calls.mostRecent().args).toEqual([jasmine.any(Function), 10000]);

    var respond = {timestamp: NaN};
    $httpBackend.expectGET('/pools/default/overviewStats').respond(200, respond);
    mnAdminOverviewService.runStatsLoop();
    $httpBackend.flush();

    expect($browser.defer.calls.mostRecent().args).toEqual([jasmine.any(Function), 15000]);

    var respond = {timestamp: [1411376148000,1411376452000,1411376456000,1411376460000,1411376464000,1411376468000]};
    $httpBackend.expectGET('/pools/default/overviewStats').respond(200, respond);
    mnAdminOverviewService.runStatsLoop();
    $httpBackend.flush();

    expect($browser.defer.calls.mostRecent().args).toEqual([jasmine.any(Function), 30000]);
  });

});