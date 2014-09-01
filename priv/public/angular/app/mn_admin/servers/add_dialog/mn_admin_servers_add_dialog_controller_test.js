describe("mnAdminServersAddDialogController", function () {
  var $scope;
  var mnAdminService;
  var mnAdminGroupsService;
  var mnAdminServersAddDialogService;
  var promise = new specRunnerHelper.MockedPromise();

  beforeEach(angular.mock.module('mnAdminServers'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    mnAdminService = $injector.get('mnAdminService');
    mnAdminGroupsService = $injector.get('mnAdminGroupsService');
    mnAdminServersAddDialogService = $injector.get('mnAdminServersAddDialogService');
    mnDialogService = $injector.get('mnDialogService');

    $scope = $rootScope.$new();

    spyOn(mnDialogService, 'removeLastOpened');
    spyOn(mnAdminServersAddDialogService, 'resetModel');
    spyOn(mnAdminServersAddDialogService, 'addServer').and.returnValue(promise);
    spyOn(mnAdminGroupsService, 'getGroups');

    $controller('mnAdminServersAddDialogController', {'$scope': $scope});

    $scope.form = new specRunnerHelper.MockedForm();
    spyOn($scope.form, '$setValidity');

    mnAdminService.model.details = {serverGroupsUri: 'serverGroupsUri', controllers: {addNode: {uri: 'uri'}}};
  }));

  it('should be properly initialized', function () {
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
    expect($scope.mnAdminServersAddDialogServiceModel).toEqual(mnAdminServersAddDialogService.model);
    expect($scope.viewLoading).toBe(false);
    expect($scope.focusMe).toBe(true);
    expect(mnAdminServersAddDialogService.resetModel).toHaveBeenCalled();
  });

  it('should validate hostname', function () {
    $scope.form.$invalid = true;
    $scope.mnAdminServersAddDialogServiceModel.newServer = {hostname: ''};
    $scope.onSubmit();
    expect($scope.form.$setValidity).toHaveBeenCalledWith('hostnameReq', false);
    expect(mnAdminServersAddDialogService.addServer).not.toHaveBeenCalled();
  });

  it('should add new server', function () {
    $scope.mnAdminServersAddDialogServiceModel.newServer = {hostname: 'test'};
    $scope.onSubmit();
    expect(mnAdminServersAddDialogService.addServer).toHaveBeenCalledWith('uri');
    expect(mnAdminGroupsService.getGroups).toHaveBeenCalledWith('serverGroupsUri');
    expect(mnDialogService.removeLastOpened).toHaveBeenCalled();
  });

  it('should show errors', function () {
    $scope.mnAdminServersAddDialogServiceModel.newServer = {hostname: 'test'};
    var errorMarker = {};
    promise.setResponse(errorMarker).switchOn('error');
    $scope.onSubmit();
    expect($scope.formErrors).toBe(errorMarker);
  });

  it('should select first group by default', function () {
    mnAdminGroupsService.model.isGroupsAvailable = true;
    var groupMarker = {};
    mnAdminGroupsService.model.groups = [groupMarker];
    $scope.$apply();
    expect(mnAdminServersAddDialogService.model.selectedGroup).toBe(groupMarker);
  });

});