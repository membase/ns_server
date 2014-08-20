describe("mnWizardStep3Service", function () {
  var $httpBackend;
  var $timeout;
  var mnWizardStep3Service;

  beforeEach(angular.mock.module('mnWizard'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnWizardStep3Service = $injector.get('mnWizardStep3Service');
  }));

  it('should be properly initialized', function () {
    expect(mnWizardStep3Service.postBuckets).toEqual(jasmine.any(Function));
    expect(mnWizardStep3Service.model).toEqual(jasmine.any(Object));
    expect(mnWizardStep3Service.getBucketConf).toEqual(jasmine.any(Function));
    expect(mnWizardStep3Service.tryToGetDefaultBucketInfo).toEqual(jasmine.any(Function));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectPOST('/pools/default/buckets','authType=sasl&bucketType=membase&evictionPolicy=valueOnly&flushEnabled=0&name=default&otherBucketsRamQuotaMB=0&ramQuotaMB=0&replicaIndex=0&replicaNumber=1&saslPassword=&threadsNumber=3').respond(200);
    mnWizardStep3Service.model.bucketConf = mnWizardStep3Service.getBucketConf();
    mnWizardStep3Service.postBuckets();
    $httpBackend.flush();
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1','authType=sasl&bucketType=membase&evictionPolicy=valueOnly&flushEnabled=0&name=default&otherBucketsRamQuotaMB=0&ramQuotaMB=0&replicaIndex=0&replicaNumber=1&saslPassword=&threadsNumber=3').respond(200);
    mnWizardStep3Service.postBuckets(true);
    $httpBackend.flush();
    $httpBackend.expectGET('/pools/default/buckets/default').respond(200)
    mnWizardStep3Service.tryToGetDefaultBucketInfo();
    $httpBackend.flush();
  });
});