describe("mnAdminServersListItemDetailsController", function () {
  var $scope;
  var $stateParams;
  var $location;
  var mnAdminService;
  var promise;

  beforeEach(angular.mock.module('mnAdminServers'));

  beforeEach(inject(function ($injector) {
    promise = new specRunnerHelper.MockedPromise({});
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $location = $injector.get('$location');
    mnAdminService = $injector.get('mnAdminService');
    mnAdminTasksService = $injector.get('mnAdminTasksService');
    mnAdminServersListItemDetailsService = $injector.get('mnAdminServersListItemDetailsService');

    spyOn(mnAdminServersListItemDetailsService, 'getNodeDetails').and.returnValue(promise);

    $scope = $rootScope.$new();

    $controller('mnAdminServersListItemDetailsController', {'$scope': $scope});
  }));

  it('should react on openedServers hash key', function () {
    $scope.node = {hostname: '0.0.0.0:9001'};
    $scope.$apply();

    expect(mnAdminServersListItemDetailsService.getNodeDetails.calls.count()).toBe(0);

    $location.search({'openedServers': ['0.0.0.0:9001']});
    promise.setResponse({uptime: 2341, storage: {hdd: [{path: '/home/pavel/projects/couchbase/ns_server/data/n_1/data'}]}});
    $scope.$apply();

    expect(mnAdminServersListItemDetailsService.getNodeDetails).toHaveBeenCalledWith($scope.node);
    expect($scope.details).toBe(promise.responseArgs[0]);
    expect($scope.ellipsisPath).toBe('...s_server/data/n_1/data');
    expect($scope.details.uptime).toBe('39 minutes, 1 second');
  });

  it('should react on mnAdminServiceModel deps changes', function () {
    $scope.node = {hostname: '0.0.0.0:9001'};
    mnAdminService.model.details = undefined;
    $scope.$apply();

    expect(mnAdminServersListItemDetailsService.getNodeDetails.calls.count()).toBe(0);

    $location.search({'openedServers': ['0.0.0.0:9001']});
    promise.setResponse({uptime: 2341, storage: {hdd: [{path: '/home/pavel/projects/couchbase/ns_server/data/n_1/data'}]}});

    mnAdminService.model.details = 'go';
    $scope.$apply();

    expect(mnAdminServersListItemDetailsService.getNodeDetails).toHaveBeenCalledWith($scope.node);
    expect($scope.details).toBe(promise.responseArgs[0]);
    expect($scope.ellipsisPath).toBe('...s_server/data/n_1/data');
    expect($scope.details.uptime).toBe('39 minutes, 1 second');
  });

  it('should have disk storage configuration', function () {
    $scope.details = {storageTotals: {hdd: {"total":265550077952,"quotaTotal":265550077952,"used":47799014031,"usedByData":16990242,"free":217751063921}}};
    $scope.$apply();
    expect($scope.getDiskStorageConfig).toEqual({ topRight : { name : 'Total', value : '247 GB' }, items : [ { name : 'In Use', value : 16990242, itemStyle : { 'background-color' : '#00BCE9' }, labelStyle : { color : '#1878A2', 'text-align' : 'left' } }, { name : 'Other Data', value : 47782023789, itemStyle : { 'background-color' : '#FDC90D' }, labelStyle : { color : '#C19710', 'text-align' : 'center' } }, { name : 'Free', value : 217751063921, itemStyle : {  }, labelStyle : { 'text-align' : 'right' } } ], markers : [  ] });
  });

  it('should have memory cache storage configuration', function () {
    $scope.details = {storageTotals: {ram: {"total":6191300608,"quotaTotal":3714056192,"quotaUsed":3714056192,"used":5756289024,"usedByData":34209352,"quotaUsedPerNode":3714056192,"quotaTotalPerNode":3714056192}}};
    $scope.$apply();
    expect($scope.getMemoryCacheConfig).toEqual({"topRight":{"name":"Total","value":"5.76 GB"},"items":[{"name":"In Use","value":34209352,"itemStyle":{"background-color":"#00BCE9"},"labelStyle":{"color":"#1878A2","text-align":"left"}},{"name":"Other Data","value":5722079672,"itemStyle":{"background-color":"#FDC90D"},"labelStyle":{"color":"#C19710","text-align":"center"}},{"name":"Free","value":435011584,"itemStyle":{},"labelStyle":{"text-align":"right"}}],"markers":[{"track":1,"value":3714056192,"itemStyle":{"background-color":"#E43A1B"}}],"topLeft":{"name":"Couchbase Quota","value":"3.45 GB"}});
  });

  it('should contains detailed progress data', function () {
    $scope.node = {otpNode: 'n_0@0.0.0.0'};
    $scope.$apply();
    $scope.mnAdminTasksServiceModel = {tasksRebalance: {"type":"rebalance","status":"notRunning"}};
    $scope.$apply();
    expect($scope.detailedProgress).toBe(false);

    $scope.mnAdminTasksServiceModel = {tasksRebalance: {"type":"rebalance","subtype":"rebalance","recommendedRefreshPeriod":0.25,"status":"running","progress":0,"perNode":{"n_0@0.0.0.0":{"progress":0},"n_1@192.168.1.101":{"progress":0}},"detailedProgress":{}}};
    $scope.$apply();
    expect($scope.detailedProgress).toBe(false);

    $scope.mnAdminTasksServiceModel = {tasksRebalance: {"type":"rebalance","subtype":"rebalance","recommendedRefreshPeriod":0.25,"status":"running","progress":21.2645566385573,"perNode":{"n_0@0.0.0.0":{"progress":36.23188405797102},"n_1@192.168.1.101":{"progress":6.297229219143574}},"detailedProgress":{"bucket":"default","bucketNumber":1,"bucketsCount":1,"perNode":{"n_1@192.168.1.101":{"ingoing":{"docsTotal":0,"docsTransferred":0,"activeVBucketsLeft":0,"replicaVBucketsLeft":44},"outgoing":{"docsTotal":0,"docsTransferred":0,"activeVBucketsLeft":44,"replicaVBucketsLeft":0}},"n_0@0.0.0.0":{"ingoing":{"docsTotal":0,"docsTransferred":0,"activeVBucketsLeft":44,"replicaVBucketsLeft":164},"outgoing":{"docsTotal":0,"docsTransferred":0,"activeVBucketsLeft":0,"replicaVBucketsLeft":0}}}}}};
    $scope.$apply();
    expect($scope.detailedProgress).toEqual({ ingoing : { docsTotal : 0, docsTransferred : 0, activeVBucketsLeft : 44, replicaVBucketsLeft : 164 }, outgoing : false, bucket : 'default', bucketNumber : 1, bucketsCount : 1 });
  });

});