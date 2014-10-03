describe("mnAdminSettingsAutoFailoverService", function () {
  var $httpBackend;
  var mnAdminSettingsAutoFailoverService;

  beforeEach(angular.mock.module('mnAdminSettingsAutoFailoverService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    $timeout = $injector.get('$timeout');
    mnAdminSettingsAutoFailoverService = $injector.get('mnAdminSettingsAutoFailoverService');
  }));

  it('should be properly initialized', function () {
    expect(mnAdminSettingsAutoFailoverService.resetAutoFailOverCount).toEqual(jasmine.any(Function));
    expect(mnAdminSettingsAutoFailoverService.getAutoFailoverSettings).toEqual(jasmine.any(Function));
  });

  it('should be able to sending requests', function () {
    $httpBackend.expectPOST('/settings/autoFailover/resetCount').respond(200);
    mnAdminSettingsAutoFailoverService.resetAutoFailOverCount();

    $httpBackend.expectGET('/settings/autoFailover').respond(200);
    mnAdminSettingsAutoFailoverService.getAutoFailoverSettings()

    $httpBackend.flush();
  });

  it('should cancel resetAutoFailOverCount request if new one on the way', function () {
    var counter = new specRunnerHelper.Counter;
    $httpBackend.expectPOST('/settings/autoFailover/resetCount').respond(counter.increment.bind(counter));
    $httpBackend.expectPOST('/settings/autoFailover/resetCount').respond(counter.increment.bind(counter));
    mnAdminSettingsAutoFailoverService.resetAutoFailOverCount();
    mnAdminSettingsAutoFailoverService.resetAutoFailOverCount();

    $httpBackend.flush();

    expect(counter.counter).toBe(1);
  });

});