describe("mnAdminServersListItemService", function () {
  var $httpBackend;
  var mnAdminServersListItemService;

  beforeEach(angular.mock.module('mnAdminServersListItemService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnAdminServersListItemService = $injector.get('mnAdminServersListItemService');
  }));

  it('should be properly initialized', function () {
    expect(mnAdminServersListItemService.addToPendingEject).toEqual(jasmine.any(Function));
    expect(mnAdminServersListItemService.removeFromPendingEject).toEqual(jasmine.any(Function));
    expect(mnAdminServersListItemService.model).toEqual(jasmine.any(Object));
    expect(mnAdminServersListItemService.model.pendingEject).toEqual(jasmine.any(Array));
  });

  it('should be able to add/remove pendingEject node', function () {
    mnAdminServersListItemService.addToPendingEject({hostname: 'hostname1'});
    expect(mnAdminServersListItemService.model.pendingEject.length).toBe(1);

    mnAdminServersListItemService.removeFromPendingEject({hostname: 'hostname1'});
    expect(mnAdminServersListItemService.model.pendingEject.length).toBe(0);
  });
});