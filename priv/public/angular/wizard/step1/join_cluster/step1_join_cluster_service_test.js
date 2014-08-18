describe("wizard.step1.joinCluster.service", function () {
  var joinClusterService;
  var $httpBackend;
  var self;

  beforeEach(angular.mock.module('wizard'));

  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    joinClusterService = $injector.get('wizard.step1.joinCluster.service');
  }));

  function populate(os) {
    self = {total: 10485760, quotaTotal: 10485760};
    joinClusterService.populateModel(self);
  }

  it('should be properly initialized', function () {
    expect(joinClusterService.model).toEqual(jasmine.any(Object));
    expect(joinClusterService.model.clusterMember).toEqual(jasmine.any(Object));
    expect(joinClusterService.resetClusterMember).toEqual(jasmine.any(Function));
    expect(joinClusterService.postMemory).toEqual(jasmine.any(Function));
    expect(joinClusterService.postJoinCluster).toEqual(jasmine.any(Function));
    expect(joinClusterService.populateModel).toEqual(jasmine.any(Function));
  });

  it('should be properly populated', function () {
    populate();
    expect(joinClusterService.model.dynamicRamQuota).toEqual(10);
    expect(joinClusterService.model.ramTotalSize).toEqual(10);
    expect(joinClusterService.model.ramMaxMegs).toEqual(8);
  });

  it('should be able to send requests', function () {
    populate();
    $httpBackend.expectPOST('/pools/default', 'memoryQuota=10').respond(200);
    $httpBackend.expectPOST('/node/controller/doJoinCluster', 'hostname=127.0.0.1&password=&user=Administrator').respond(200);
    joinClusterService.postMemory();
    joinClusterService.postJoinCluster();
    $httpBackend.flush();
  });

});