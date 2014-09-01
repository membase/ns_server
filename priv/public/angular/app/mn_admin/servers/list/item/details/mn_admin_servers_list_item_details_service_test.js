describe("mnAdminServersListItemDetailsService", function () {
  var $httpBackend;
  var mnAdminServersListItemDetailsService;

  beforeEach(angular.mock.module('mnAdminServersListItemDetailsService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnAdminServersListItemDetailsService = $injector.get('mnAdminServersListItemDetailsService');
  }));

  it('should be properly initialized', function () {
    expect(mnAdminServersListItemDetailsService.getNodeDetails).toEqual(jasmine.any(Function));
  });

  it('should properly send requests', function () {
    $httpBackend.expectGET('/nodes/test%20test').respond(200);
    mnAdminServersListItemDetailsService.getNodeDetails({otpNode:  'test test'});
    $httpBackend.flush();
  });
});