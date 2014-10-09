describe("mnAdminController", function () {
  var $scope;
  var $state;
  var mnAuthService;
  var mnAdminService;
  var mnAdminGroupsService;
  var mnAdminServersService;
  var mnAdminTasksService;
  var mnAdminServersListItemService;

  beforeEach(angular.mock.module('mnAdmin'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $state = $injector.get('$state');
    mnAuthService = $injector.get('mnAuthService');
    mnAdminService = $injector.get('mnAdminService');
    mnAdminGroupsService = $injector.get('mnAdminGroupsService');
    mnAdminServersService = $injector.get('mnAdminServersService');
    mnAdminTasksService = $injector.get('mnAdminTasksService');
    mnAdminServersListItemService = $injector.get('mnAdminServersListItemService');

    spyOn(mnAuthService, 'entryPoint');
    spyOn(mnAdminService, 'runDefaultPoolsDetailsLoop');
    spyOn(mnAdminServersService, 'populateNodesModel');
    spyOn(mnAdminGroupsService, 'setIsGroupsAvailable');
    spyOn(mnAdminGroupsService, 'getGroups');
    spyOn(mnAdminTasksService, 'runTasksLoop');
    spyOn(mnAdminTasksService, 'stopTasksLoop');
    spyOn(mnAdminService, 'stopDefaultPoolsDetailsLoop');
    spyOn(mnAdminService, 'waitChangeOfPoolsDetailsLoop').and.callThrough();

    $scope = $rootScope.$new();

    $controller('mnAdminController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.$state).toBeDefined();
    expect($scope.$location).toBeDefined();
    expect($scope.Math).toBeDefined();
    expect($scope._).toBeDefined();
    expect($scope.logout).toBeDefined(jasmine.any(Function));
    expect($scope.mnAdminServiceModel).toBe(mnAdminService.model);
    expect($scope.mnAdminGroupsServiceModel).toBe(mnAdminGroupsService.model);
    expect($scope.mnAdminServersServiceModel).toBe(mnAdminServersService.model);
    expect($scope.mnAdminTasksServiceModel).toBe(mnAdminTasksService.model);
    expect(mnAdminService.runDefaultPoolsDetailsLoop).toHaveBeenCalled();
  });

  it('should react on runTasksLoop deps changes', function () {
    $scope.$apply();
    expect(mnAdminTasksService.runTasksLoop.calls.count()).toBe(1);
    mnAdminService.model.details = {tasks: {uri: 'test'}};
    $scope.$apply();
    expect(mnAdminTasksService.runTasksLoop.calls.count()).toBe(2);
  });

  it('should react on getGroups deps changes', function () {
    $scope.$apply();
    expect(mnAdminService.getGroups.calls.count()).toBe(1);
    mnAdminService.model.details = {serverGroupsUri: 'test'};
    $scope.$apply();
    expect(mnAdminService.getGroups.calls.count()).toBe(2);
  });

  it('should react on populateNodesModel deps changes', function () {
    mnAdminService.model.details = undefined;
    $scope.$apply();
    expect(mnAdminServersService.populateNodesModel.calls.count()).toBe(0);

    mnAdminService.model.details = {nodes: 'test'};
    $scope.$apply();
    expect(mnAdminServersService.populateNodesModel.calls.count()).toBe(1);

    mnAdminService.model.isGroupsAvailable = true;
    $scope.$apply();
    expect(mnAdminServersService.populateNodesModel.calls.count()).toBe(2);

    mnAdminService.model.hostnameToGroup = 'test';
    $scope.$apply();
    expect(mnAdminServersService.populateNodesModel.calls.count()).toBe(3);

    mnAdminServersListItemService.model.pendingEject = ['test'];
    $scope.$apply();
    expect(mnAdminServersService.populateNodesModel.calls.count()).toBe(4);

    expect(mnAdminServersService.populateNodesModel).toHaveBeenCalledWith({ isGroupsAvailable : true, hostnameToGroup : 'test', nodes : 'test', pendingEjectLength : 1, pendingEject : [ 'test' ] });
  });

  it('should react on setIsGroupsAvailable deps changes', function () {
    $scope.$apply();
    expect(mnAdminGroupsService.setIsGroupsAvailable.calls.count()).toBe(1);
    expect(mnAdminGroupsService.setIsGroupsAvailable.calls.mostRecent().args[0]).toEqual(false);
    mnAuthService.model.isEnterprise = true
    mnAdminService.model.details = {serverGroupsUri: 'test'};
    $scope.$apply();
    expect(mnAdminGroupsService.setIsGroupsAvailable.calls.count()).toBe(2);
    expect(mnAdminGroupsService.setIsGroupsAvailable.calls.mostRecent().args[0]).toEqual(true);
  });

  it('should recalculate PoolsDetailsLoop params if state is changed', function () {
    $state.current.name = 'admin.overview';
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(2);

    $state.current.name = 'admin.overview';
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(2);

    $state.current.name = "whatever";
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(3);
  });

  it('should break loops on scope destroy', function () {
    $scope.$destroy();
    expect(mnAdminTasksService.stopTasksLoop).toHaveBeenCalled();
    expect(mnAdminService.stopDefaultPoolsDetailsLoop).toHaveBeenCalled();
  });

});