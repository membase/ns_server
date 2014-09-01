describe("mnAdminServersFailOverDialogService", function () {
  var $httpBackend;
  var mnAdminServersFailOverDialogService;

  beforeEach(angular.mock.module('mnAdminServersFailOverDialogService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnAdminServersFailOverDialogService = $injector.get('mnAdminServersFailOverDialogService');
  }));

  it('should be properly initialized', function () {
    expect(mnAdminServersFailOverDialogService.model).toEqual(jasmine.any(Object));
    expect(mnAdminServersFailOverDialogService.getNodeStatuses).toEqual(jasmine.any(Function));
  });

  it('should properly send requests', function () {
    $httpBackend.expectGET('test').respond(200);
    mnAdminServersFailOverDialogService.getNodeStatuses('test');
    $httpBackend.flush();
  });
});