describe("wizard.step3.Controller", function () {
  var step3Service;
  var step2Service;
  var joinClusterService;
  var $httpBackend;
  var $scope;
  var $state;
  var createController;

  beforeEach(angular.mock.module('wizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    joinClusterService = $injector.get('wizard.step1.joinCluster.service');
    step3Service = $injector.get('wizard.step3.service');
    step2Service = $injector.get('wizard.step2.service');
    $state = $injector.get('$state');

    spyOn($state, 'transitionTo');

    $scope = $rootScope.$new();

    createController = function createController() {
      return $controller('wizard.step3.Controller', {'$scope': $scope});
    }
  }));

  it('should be properly initialized', function () {
    createController();
    expect($scope.guageConfig).toEqual({});
    expect($scope.modelStep3Service).toBe(step3Service.model);
    expect($scope.focusMe).toEqual(true);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
  });

  it('should set ramQuotaMB on initialize', function () {
    joinClusterService.model.dynamicRamQuota = 100000;
    step2Service.model.sampleBucketsRAMQuota = 9999999999;
    createController();
    expect(step3Service.model.bucketConf.ramQuotaMB).toBe(90464);
  });

  it('should go to next step if there are no errors', function () {
    createController();
    $scope.errors = {error: 'error'};
    $scope.onSubmit();
    expect($state.transitionTo.calls.count()).toBe(0);
    $scope.errors = {};
    $scope.onSubmit();
    expect($state.transitionTo.calls.count()).toBe(1);
  });

  it('should checking bucketConf on errors in live time', function () {
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(200);
    createController();
    $scope.$apply();
    $httpBackend.flush();
  });

  it('should populate guageConfig', function () {
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1').respond(200, {summaries: {ramSummary: {thisAlloc: 200000, nodesCount: 2, perNodeMegs: 100, total: 20000000, otherBuckets: 1111111}}});
    createController();
    $scope.$apply();
    $httpBackend.flush();
    expect($scope.guageConfig).toEqual({ topRight : { name : 'Cluster quota', value : '19 MB' }, items : [ { name : 'Other Buckets', value : 1111111, itemStyle : { 'background-color' : '#00BCE9', 'z-index' : '2' }, labelStyle : { color : '#1878a2', 'text-align' : 'left' } }, { name : 'This Bucket', value : 200000, itemStyle : { 'background-color' : '#7EDB49', 'z-index' : '1' }, labelStyle : { color : '#409f05', 'text-align' : 'center' } }, { name : 'Free', value : 18688889, itemStyle : { 'background-color' : '#E1E2E3' }, labelStyle : { color : '#444245', 'text-align' : 'right' } } ], markers : [  ] });
  });

});