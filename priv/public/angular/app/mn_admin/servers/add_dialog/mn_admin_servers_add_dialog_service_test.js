describe("mnAdminServersAddDialogService", function () {
  var $httpBackend;
  var mnAdminServersAddDialogService;

  beforeEach(angular.mock.module('mnAdminServersAddDialogService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnAdminServersAddDialogService = $injector.get('mnAdminServersAddDialogService');
  }));

  it('should be properly initialized', function () {
    expect(mnAdminServersAddDialogService.resetModel).toEqual(jasmine.any(Function));
    expect(mnAdminServersAddDialogService.addServer).toEqual(jasmine.any(Function));
    expect(mnAdminServersAddDialogService.model).toEqual(jasmine.any(Object));
    expect(mnAdminServersAddDialogService.model.newServer).toEqual({});
  });

  it('should reset model', function () {
    mnAdminServersAddDialogService.model.newServer = 'initialNewServer';
    mnAdminServersAddDialogService.model.selectedGroup = 'selectedGroup';
    mnAdminServersAddDialogService.resetModel();
    expect(mnAdminServersAddDialogService.model.newServer).toEqual({ hostname : '', user : 'Administrator', password : '' });
  });

  it('should add server', function () {
    $httpBackend.expectPOST('test').respond(200);
    mnAdminServersAddDialogService.addServer('test');
    $httpBackend.flush();

    mnAdminServersAddDialogService.model.newServer = {hi: 'hello'};
    mnAdminServersAddDialogService.model.selectedGroup = {addNodeURI: 'addNodeURI', newServer: {}};
    $httpBackend.expectPOST('addNodeURI', "hi=hello").respond(200);
    mnAdminServersAddDialogService.addServer();
    $httpBackend.flush();
  });
});