describe("mnWizardStep1JoinClusterService", function () {
  var mnWizardStep1JoinClusterService;
  var $httpBackend;
  var self;

  beforeEach(angular.mock.module('mnWizard'));

  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnWizardStep1JoinClusterService = $injector.get('mnWizardStep1JoinClusterService');
  }));

  function populate(os) {
    self = {total: 10485760, quotaTotal: 10485760};
    mnWizardStep1JoinClusterService.populateModel(self);
  }

  it('should be properly initialized', function () {
    expect(mnWizardStep1JoinClusterService.model).toEqual(jasmine.any(Object));
    expect(mnWizardStep1JoinClusterService.model.clusterMember).toEqual(jasmine.any(Object));
    expect(mnWizardStep1JoinClusterService.resetClusterMember).toEqual(jasmine.any(Function));
    expect(mnWizardStep1JoinClusterService.postMemory).toEqual(jasmine.any(Function));
    expect(mnWizardStep1JoinClusterService.postJoinCluster).toEqual(jasmine.any(Function));
    expect(mnWizardStep1JoinClusterService.populateModel).toEqual(jasmine.any(Function));
  });

  it('should be properly populated', function () {
    populate();
    expect(mnWizardStep1JoinClusterService.model.dynamicRamQuota).toEqual(10);
    expect(mnWizardStep1JoinClusterService.model.ramTotalSize).toEqual(10);
    expect(mnWizardStep1JoinClusterService.model.ramMaxMegs).toEqual(8);
  });

  it('should be able to send requests', function () {
    populate();
    $httpBackend.expectPOST('/pools/default', 'memoryQuota=10').respond(200);
    $httpBackend.expectPOST('/node/controller/doJoinCluster', 'hostname=127.0.0.1&password=&user=Administrator').respond(200);
    mnWizardStep1JoinClusterService.postMemory();
    mnWizardStep1JoinClusterService.postJoinCluster();
    $httpBackend.flush();
  });

});