describe("mnAdminServersListItemController", function () {
  var $scope;
  var $stateParams;
  var $location;
  var mnDialogService;
  var mnAdminService;
  var mnAdminServersListItemService;
  var mnAdminServersService;
  var promise;

  beforeEach(angular.mock.module('mnAdminServers'));

  beforeEach(inject(function ($injector) {
    promise = new specRunnerHelper.MockedPromise();
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    mnDialogService = $injector.get('mnDialogService');
    mnAdminService = $injector.get('mnAdminService');
    mnAdminServersListItemService = $injector.get('mnAdminServersListItemService');
    mnAdminServersService = $injector.get('mnAdminServersService');
    $location = $injector.get('$location');

    spyOn(mnDialogService, 'open');
    spyOn(mnAdminServersListItemService, 'removeFromPendingEject');
    spyOn(mnAdminServersService, 'postAndReload');

    $scope = $rootScope.$new();

    $controller('mnAdminServersListItemController', {'$scope': $scope});
  }));

  it('should properly initialized', function () {
    expect($scope.reAddNode).toEqual(jasmine.any(Function));
    expect($scope.doEjectServer).toEqual(jasmine.any(Function));
    expect($scope.ejectServer).toEqual(jasmine.any(Function));
    expect($scope.cancelFailOverNode).toEqual(jasmine.any(Function));
    expect($scope.failOverNode).toEqual(jasmine.any(Function));
    expect($scope.cancelEjectServer).toEqual(jasmine.any(Function));
    expect($scope.toggleDetails).toEqual(jasmine.any(Function));
  });

  it('should open eject server dialog', function () {
    $scope.ejectServer();
    expect(mnDialogService.open).toHaveBeenCalledWith({
      template: '/angular/app/mn_admin/servers/eject_dialog/mn_admin_servers_eject_dialog.html',
      scope: $scope
    });
  });

  it('should open failover dialog', function () {
    $scope.failOverNode();
    expect(mnDialogService.open).toHaveBeenCalledWith({
      template: '/angular/app/mn_admin/servers/failover_dialog/mn_admin_servers_failover_dialog.html',
      scope: $scope
    });
  });

  it('should readd node', function () {
    mnAdminService.model = {details: {controllers: {setRecoveryType: {uri: 'url'}}}};
    $scope.node = 'test node';
    $scope.reAddNode('type');
    expect(mnAdminServersService.postAndReload).toHaveBeenCalledWith('url', { otpNode : undefined, recoveryType : 'type' });
  });

  it('should cancel failover node', function () {
    mnAdminService.model = {details: {controllers: {reFailOver: {uri: 'url'}}}};
    $scope.node = 'test node';
    $scope.cancelFailOverNode();
    expect(mnAdminServersService.postAndReload).toHaveBeenCalledWith('url', { otpNode : undefined });
  });

  it('should cancel server ejection', function () {
    $scope.node = 'test node';
    $scope.cancelEjectServer();
    expect(mnAdminServersListItemService.removeFromPendingEject).toHaveBeenCalledWith('test node');
  });

  it('should toggle node details hostname', function () {
    mnAdminService.model.nodes = {reallyActive: []};
    $scope.nodesList = [];
    $location.search({'openedServers': ['0.0.0.0:9001','0.0.0.0:9002','0.0.0.0:9003']});
    $scope.node = {"systemStats":{"cpu_utilization_rate":76.5,"swap_total":6291451904,"swap_used":0,"mem_total":6191300608,"mem_free":2507350016},"interestingStats":{"cmd_get":0,"couch_docs_actual_disk_size":15172420,"couch_docs_data_size":15157248,"couch_views_actual_disk_size":0,"couch_views_data_size":0,"curr_items":0,"curr_items_tot":0,"ep_bg_fetched":0,"get_hits":0,"mem_used":33098960,"ops":0,"vb_replica_curr_items":0},"uptime":"22550","memoryTotal":6191300608,"memoryFree":2507350016,"mcdMemoryReserved":4723,"mcdMemoryAllocated":4723,"couchApiBase":"http://0.0.0.0:9501/","clusterMembership":"active","recoveryType":"none","status":"warmup","otpNode":"n_1@0.0.0.0","thisNode":true,"hostname":"0.0.0.0:9001","clusterCompatibility":196608,"version":"3.0.0r-902-g3d88063","os":"x86_64-pc-linux-gnu","ports":{"proxy":12003,"direct":12002},"group":"Group 1","rebalanceProgressPercent":0};
    $scope.$apply();
    $scope.toggleDetails();
    expect($location.search()['openedServers']).toEqual(['0.0.0.0:9002','0.0.0.0:9003']);
    $scope.$apply();
    $scope.toggleDetails();
    expect($location.search()['openedServers']).toEqual(['0.0.0.0:9002','0.0.0.0:9003','0.0.0.0:9001']);
  });

  it('should properly create scope properties', function () {
    mnAdminService.model.nodes = {reallyActive: []};
    $scope.nodesList = [];
    $location.search({'openedServers': ['0.0.0.0:9001','0.0.0.0:9002','0.0.0.0:9003']});
    $scope.node = {"systemStats":{"cpu_utilization_rate":76.5,"swap_total":6291451904,"swap_used":0,"mem_total":6191300608,"mem_free":2507350016},"interestingStats":{"cmd_get":0,"couch_docs_actual_disk_size":15172420,"couch_docs_data_size":15157248,"couch_views_actual_disk_size":0,"couch_views_data_size":0,"curr_items":0,"curr_items_tot":0,"ep_bg_fetched":0,"get_hits":0,"mem_used":33098960,"ops":0,"vb_replica_curr_items":0},"uptime":"22550","memoryTotal":6191300608,"memoryFree":2507350016,"mcdMemoryReserved":4723,"mcdMemoryAllocated":4723,"couchApiBase":"http://0.0.0.0:9501/","clusterMembership":"active","recoveryType":"none","status":"warmup","otpNode":"n_1@0.0.0.0","thisNode":true,"hostname":"0.0.0.0:9001","clusterCompatibility":196608,"version":"3.0.0r-902-g3d88063","os":"x86_64-pc-linux-gnu","ports":{"proxy":12003,"direct":12002},"group":"Group 1","rebalanceProgressPercent":0};
    $scope.$apply();
    expect($scope.couchDataSize).toEqual('14.4MB');
    expect($scope.couchDiskUsage).toEqual('14.4MB');
    expect($scope.currItems).toEqual(0);
    expect($scope.currVbItems).toEqual(0);
    expect($scope.isDataDiskUsageAvailable).toEqual(true);
    expect($scope.isNodeUnhealthy).toEqual(false);
    expect($scope.isNodeInactiveFaied).toEqual(false);
    expect($scope.isNodeInactiveAdded).toEqual(false);
    expect($scope.isReAddPossible).toEqual(false);
    expect($scope.isActiveUnhealthy).toEqual(false);
    expect($scope.isDetailsOpened).toEqual(true);
    expect($scope.isLastActive).toEqual(false);
    expect($scope.safeNodeOtpNode).toEqual('n__005f1__00400__002e0__002e0__002e0');
    expect($scope.strippedPort).toEqual('0.0.0.0:9001');
    expect($scope.ramUsageConf).toEqual({ exist : true, height : 59.50204690820272, top : 45.49795309179728, value : 59.5 });
    expect($scope.swapUsageConf).toEqual({ exist : true, height : 0, top : 105, value : 0 });
    expect($scope.cpuUsageConf).toEqual({ exist : true, height : 76.5, top : 28.5, value : 76.5 });
  });

});