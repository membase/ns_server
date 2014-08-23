describe("mnWizardStep3Controller", function () {
  var mnWizardStep3Service;
  var mnWizardStep2Service;
  var mnWizardStep1JoinClusterService;
  var $httpBackend;
  var $scope;
  var $state;
  var createController;
  var response = {replicaNumber: 1, hello: 'there', quota: {rawRAM: 1000000000}};

  beforeEach(angular.mock.module('mnWizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    mnWizardStep1JoinClusterService = $injector.get('mnWizardStep1JoinClusterService');
    mnWizardStep3Service = $injector.get('mnWizardStep3Service');
    mnWizardStep2Service = $injector.get('mnWizardStep2Service');
    $state = $injector.get('$state');

    spyOn($state, 'transitionTo');

    $scope = $rootScope.$new();

    createController = function createController() {
      return $controller('mnWizardStep3Controller', {'$scope': $scope});
    }
  }));

  it('should be properly initialized if default bucket not presented', function () {
    expect($scope.focusMe).toBe(undefined);
    expect($scope.replicaNumberEnabled).toBe(undefined);
    mnWizardStep1JoinClusterService.model.dynamicRamQuota = 100000;
    mnWizardStep2Service.model.sampleBucketsRAMQuota = 9999999999;
    $httpBackend.expectGET('/pools/default/buckets/default').respond(404);
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(200);
    createController();
    $httpBackend.flush();
    expect(mnWizardStep3Service.model.bucketConf.ramQuotaMB).toBe(90464);
    expect($scope.guageConfig).toEqual({});
    expect($scope.modelStep3Service.bucketConf).toBe(mnWizardStep3Service.model.bucketConf);
    expect($scope.modelStep3Service.isDefaultBucketPresented).toBe(undefined);
    expect($scope.focusMe).toBe(true);
    expect($scope.viewLoading).toBe(false);
    expect($scope.replicaNumberEnabled).toBe(true);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
  });

  it('should be properly initialized if default bucket presented', function () {
    expect($scope.focusMe).toBe(undefined);
    expect($scope.replicaNumberEnabled).toBe(undefined);
    $httpBackend.expectGET('/pools/default/buckets/default').respond(200, response);
    $httpBackend.expectPOST('/pools/default/buckets/default?ignore_warnings=1&just_validate=1').respond(200);
    createController();
    $httpBackend.flush();
    expect($scope.guageConfig).toEqual({});
    expect($scope.modelStep3Service.bucketConf).toEqual({ replicaNumber : 1, otherBucketsRamQuotaMB : 0, ramQuotaMB : 953 });
    expect($scope.modelStep3Service.isDefaultBucketPresented).toBe(true);
    expect($scope.focusMe).toBe(true);
    expect($scope.viewLoading).toBe(false);
    expect($scope.replicaNumberEnabled).toBe(true);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
  });

  it('should going to the next step if there are no errors', function () {
    createController();
    $httpBackend.expectGET('/pools/default/buckets/default').respond(400);
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(200);
    $httpBackend.flush();

    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(400);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($state.transitionTo.calls.count()).toBe(0);

    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($state.transitionTo.calls.count()).toBe(1);

    $scope.modelStep3Service.isDefaultBucketPresented = true;

    $httpBackend.expectPOST('/pools/default/buckets/default').respond(400);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($state.transitionTo.calls.count()).toBe(1);

    $httpBackend.expectPOST('/pools/default/buckets/default').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($state.transitionTo.calls.count()).toBe(2);
  });

  it('should checking bucketConf on errors in live time', function () {
    $httpBackend.expectGET('/pools/default/buckets/default').respond(404);
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(200);
    createController();
    $httpBackend.flush();
  });

  it('should populate guageConfig', function () {
    $httpBackend.expectGET('/pools/default/buckets/default').respond(404);
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(200, {summaries: {ramSummary: {thisAlloc: 200000, nodesCount: 2, perNodeMegs: 100, total: 20000000, otherBuckets: 1111111}}});
    createController();
    $httpBackend.flush();
    expect($scope.guageConfig).toEqual({ topRight : { name : 'Cluster quota', value : '19 MB' }, items : [ { name : 'Other Buckets', value : 1111111, itemStyle : { 'background-color' : '#00BCE9', 'z-index' : '2' }, labelStyle : { color : '#1878a2', 'text-align' : 'left' } }, { name : 'This Bucket', value : 200000, itemStyle : { 'background-color' : '#7EDB49', 'z-index' : '1' }, labelStyle : { color : '#409f05', 'text-align' : 'center' } }, { name : 'Free', value : 18688889, itemStyle : { 'background-color' : '#E1E2E3' }, labelStyle : { color : '#444245', 'text-align' : 'right' } } ], markers : [  ] });
  });

});