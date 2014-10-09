describe("mnAdminServersController", function () {
  var $scope;
  var mnDialogService;
  var mnAdminServersService;
  var mnAdminTasksService;
  var mnAdminService;
  var mnAdminServersListItemService;
  var $state;
  var promise;
  var $stateParams;
  var $timeout;
  var mnAdminSettingsAutoFailoverService;

  beforeEach(angular.mock.module('mnAdminServers'));

  beforeEach(inject(function ($injector) {
    promise = new specRunnerHelper.MockedPromise();
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    mnDialogService = $injector.get('mnDialogService');
    mnAdminServersService = $injector.get('mnAdminServersService');
    mnAdminTasksService = $injector.get('mnAdminTasksService');
    mnAdminService = $injector.get('mnAdminService');
    mnAdminServersListItemService = $injector.get('mnAdminServersListItemService');
    mnAdminSettingsAutoFailoverService = $injector.get('mnAdminSettingsAutoFailoverService');
    $state = $injector.get('$state');
    $timeout = $injector.get('$timeout');
    $stateParams = $injector.get('$stateParams');

    spyOn(mnAdminServersService, 'populateFailoverWarningsModel');
    spyOn(mnAdminServersService, 'populateRebalanceModel');
    spyOn(mnAdminServersService, 'populatePerNodeRepalanceProgress');
    spyOn(mnDialogService, 'open');
    spyOn($state, 'go');
    spyOn(mnAdminServersService, 'postAndReload').and.returnValue(promise);
    spyOn(mnAdminServersService, 'onStopRebalance').and.returnValue(promise);
    spyOn(mnDialogService, 'removeLastOpened');
    spyOn(mnAdminSettingsAutoFailoverService, 'getAutoFailoverSettings').and.returnValue(promise);
    spyOn(mnAdminSettingsAutoFailoverService, 'resetAutoFailOverCount').and.returnValue(promise);

    $scope = $rootScope.$new();

    $controller('mnAdminServersController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.addServer).toEqual(jasmine.any(Function));
    expect($scope.onRebalance).toEqual(jasmine.any(Function));
    expect($scope.onStopRebalance).toEqual(jasmine.any(Function));
    expect($scope.onStopRecovery).toEqual(jasmine.any(Function));
    expect($scope.resetAutoFailOverCount).toEqual(jasmine.any(Function));
  });

  it('should reset auto failover count', function () {
    expect($scope.isResetAutoFailOverCountSuccess).toBe(undefined);
    $scope.resetAutoFailOverCount();
    expect($scope.isResetAutoFailOverCountSuccess).toBe(true);
    $timeout.flush();
    expect($scope.isAutoFailOverCountAvailable).toBe(false);
    expect($scope.isResetAutoFailOverCountSuccess).toBe(false);
  });

  it('should display additional confiramtion on stop rebalance error', function () {
    spyOn(mnDialogService, 'getLastOpened').and.returnValue(false);
    promise.setResponse(undefined, 400).switchOn('error');
    mnAdminService.model.details = {stopRebalanceUri: "stopRebalanceUri"};
    $scope.onStopRebalance();
    expect(mnDialogService.open).toHaveBeenCalledWith({
      template: '/angular/app/mn_admin/servers/stop_rebalance_dialog/mn_admin_servers_stop_rebalance_dialog.html',
      scope: $scope
    });
  });

  it('should display close additional confiramtion dialog on success', function () {
    spyOn(mnDialogService, 'getLastOpened').and.returnValue(true);
    expect($scope.mnDialogStopRebalanceDialogLoading).toBe(undefined);
    mnAdminService.model.details = {stopRebalanceUri: "stopRebalanceUri"};
    promise.switchOn('success');
    $scope.onStopRebalance()
    expect(mnDialogService.removeLastOpened).toHaveBeenCalled();
    expect($scope.mnDialogStopRebalanceDialogLoading).toBe(false);
  });

  it('should react on getAutoFailoverSettings deps changes', function () {
    $scope.$apply();
    expect(mnAdminSettingsAutoFailoverService.getAutoFailoverSettings.calls.count()).toBe(1);

    mnAdminService.model.nodes = 'test';
    $scope.$apply();
    expect(mnAdminSettingsAutoFailoverService.getAutoFailoverSettings.calls.count()).toBe(2);

    mnAdminTasksService.model.inRecoveryMode = 'test';
    $scope.$apply();
    expect(mnAdminSettingsAutoFailoverService.getAutoFailoverSettings.calls.count()).toBe(3);

    mnAdminTasksService.model.isLoadingSamples = 'test';
    $scope.$apply();
    expect(mnAdminSettingsAutoFailoverService.getAutoFailoverSettings.calls.count()).toBe(4);
    expect($scope.isAutoFailOverCountAvailable).toBe(false);

    mnAdminServersService.model.mayRebalanceWithoutSampleLoading = 'test';
    promise.setResponse({count: 1});
    $scope.$apply();
    expect(mnAdminSettingsAutoFailoverService.getAutoFailoverSettings.calls.count()).toBe(5);
    expect($scope.isAutoFailOverCountAvailable).toBe(true);
  });

  it('should react on populateFailoverWarningsModel deps changes', function () {
    $scope.$apply();
    expect(mnAdminServersService.populateFailoverWarningsModel.calls.count()).toBe(1);
    $scope.mnAdminServiceModel = {details: {failoverWarnings: 'test'}};
    $scope.$apply();
    expect(mnAdminServersService.populateFailoverWarningsModel.calls.count()).toBe(2);
  });

  it('should react on populateRebalanceModel deps changes', function () {
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(1);

    mnAdminService.model = {details: undefined};
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(1);

    mnAdminService.model = {details: {nodes: 'test'}};
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(1);

    mnAdminService.model = {details: {nodes: 'test'}};
    mnAdminService.model.nodes = {};
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(2);

    mnAdminTasksService.model.inRecoveryMode = 'test';
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(3);

    mnAdminTasksService.model.isLoadingSamples = 'test';
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(4);

    mnAdminService.model.details.rebalanceStatus = 'test';
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(5);

    mnAdminService.model.details.balanced = 'test';
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(6);

    mnAdminService.model.nodes.unhealthyActive = 'test'
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(7);

    mnAdminService.model.nodes.pending = 'test';
    $scope.$apply();
    expect(mnAdminServersService.populateRebalanceModel.calls.count()).toBe(8);
  });

  it('should react on populatePerNodeRepalanceProgress deps changes', function () {
    $scope.$apply();
    expect(mnAdminServersService.populatePerNodeRepalanceProgress.calls.count()).toBe(1);

    mnAdminService.model.nodes = undefined;
    mnAdminTasksService.model.tasksRebalance = 'test';
    $scope.$apply();
    expect(mnAdminServersService.populatePerNodeRepalanceProgress.calls.count()).toBe(1);

    mnAdminService.model.nodes = {allNodes: 'test'};
    $scope.$apply();
    expect(mnAdminServersService.populatePerNodeRepalanceProgress.calls.count()).toBe(2);

    mnAdminTasksService.model.tasksRebalance = 'test2';
    $scope.$apply();
    expect(mnAdminServersService.populatePerNodeRepalanceProgress.calls.count()).toBe(3);
  });

  it('should open add server dialog', function () {
    $scope.addServer();
    expect(mnDialogService.open).toHaveBeenCalledWith({
      template: '/angular/app/mn_admin/servers/add_dialog/mn_admin_servers_add_dialog.html',
      scope: $scope
    });
  });

  it('should run rebalance', function () {
    mnAdminServersListItemService.model.pendingEject = [{otpNode: 'test'}, {otpNode: 'test2'}];
    mnAdminService.model.nodes = {allNodes: [{otpNode: 'test'}, {otpNode: 'test2'}]};
    mnAdminService.model.details = {controllers: {rebalance: {uri: "test"}}};

    $scope.onRebalance();
    expect(mnAdminServersService.postAndReload).toHaveBeenCalledWith('test', {
      knownNodes: 'test,test2',
      ejectedNodes: 'test,test2'
    });
    expect($state.go.calls.count()).toBe(1);
  });

  it('should stop recovery', function () {
    mnAdminTasksService.model.stopRecoveryURI = 'stopRecoveryURI';
    $scope.onStopRecovery();
    expect(mnAdminServersService.postAndReload).toHaveBeenCalledWith('stopRecoveryURI');
  });
});