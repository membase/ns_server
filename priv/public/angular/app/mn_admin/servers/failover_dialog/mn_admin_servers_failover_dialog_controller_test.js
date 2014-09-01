describe("mnAdminServersFailOverDialogController", function () {
  var $scope;
  var mnAdminServersFailOverDialogService;
  var mnAdminService;
  var mnAdminServersService;
  var createController;
  var mnDialogService;
  var promise = new specRunnerHelper.MockedPromise;

  beforeEach(angular.mock.module('mnAdminServers'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    mnAdminServersFailOverDialogService = $injector.get('mnAdminServersFailOverDialogService');
    mnAdminService = $injector.get('mnAdminService');
    mnDialogService = $injector.get('mnDialogService');
    mnAdminServersService = $injector.get('mnAdminServersService');

    createController = function () {
      $scope = $rootScope.$new();
      $scope.node = {hostname: "0.0.0.0:9000"};
      $controller('mnAdminServersFailOverDialogController', {'$scope': $scope});
    };

    spyOn(mnDialogService, 'removeLastOpened');
    spyOn(mnAdminServersFailOverDialogService, 'getNodeStatuses').and.returnValue(promise);
    spyOn(mnAdminServersService, 'postAndReload').and.returnValue(promise);
  }));

  it('should be properly initialized', function () {
    mnAdminService.model.details = {nodeStatusesUri: 'nodeStatusesUri'};
    promise.setResponse({"0.0.0.0:9000":{"status":"healthy","gracefulFailoverPossible":true,"otpNode":"n_0@0.0.0.0","replication":1},"192.168.1.101:9001":{"status":"healthy","gracefulFailoverPossible":false,"otpNode":"n_1@192.168.1.101","replication":0}});
    createController();

    expect($scope.failoverDialogModel).toBe(mnAdminServersFailOverDialogService.model);
    expect(mnAdminServersFailOverDialogService.getNodeStatuses).toHaveBeenCalledWith('nodeStatusesUri');
    expect($scope.failoverDialogModel.nodeStatuses).toBe(promise.responseArgs[0]);
    expect($scope.confirmation).toBe(true);
    expect($scope.down).toBe(false);
    expect($scope.backfill).toBe(false);
    expect($scope.failOver).toBe('startGracefulFailover');
    expect($scope.gracefulFailoverPossible).toBe(true);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));

    promise.setResponse({"0.0.0.0:9000":{"status":"unhealthy","gracefulFailoverPossible":false,"otpNode":"n_0@0.0.0.0","replication":0},"192.168.1.101:9001":{"status":"healthy","gracefulFailoverPossible":false,"otpNode":"n_1@192.168.1.101","replication":0}});
    createController();
    expect($scope.backfill).toBe(true);
    expect($scope.confirmation).toBe(false);
    expect($scope.down).toBe(true);
    expect($scope.failOver).toBe('failOver');
    expect($scope.gracefulFailoverPossible).toBe(false);
  });

  it('should post fail over node', function () {
    mnAdminService.model.details = {controllers: {failOver: {uri: 'failOverUri'}}};
    createController();
    $scope.failOver = 'failOver';
    $scope.onSubmit();
    expect(mnAdminServersService.postAndReload).toHaveBeenCalledWith('failOverUri', { otpNode : undefined }, { timeout : 120000 });
    expect(mnDialogService.removeLastOpened).toHaveBeenCalled();
  });

});