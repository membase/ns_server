describe("wizard.step3.service", function () {
  var $httpBackend;
  var $timeout;
  var service;

  beforeEach(angular.mock.module('wizard'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    service = $injector.get('wizard.step3.service');
  }));

  it('should be properly initialized', function () {
    expect(service.postBuckets).toEqual(jasmine.any(Function));
    expect(service.model).toEqual(jasmine.any(Object));
    expect(service.getBucketConf).toEqual(jasmine.any(Function));
    expect(service.tryToGetDefaultBucketInfo).toEqual(jasmine.any(Function));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectPOST('/pools/default/buckets','authType=sasl&name=default&saslPassword=&bucketType=membase&evictionPolicy=valueOnly&replicaNumber=1&replicaIndex=0&threadsNumber=3&flushEnabled=0&ramQuotaMB=0&otherBucketsRamQuotaMB=0').respond(200);
    service.model.bucketConf = service.getBucketConf();
    service.postBuckets();
    $httpBackend.flush();
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1','authType=sasl&name=default&saslPassword=&bucketType=membase&evictionPolicy=valueOnly&replicaNumber=1&replicaIndex=0&threadsNumber=3&flushEnabled=0&ramQuotaMB=0&otherBucketsRamQuotaMB=0').respond(200);
    service.postBuckets(true);
    $httpBackend.flush();
    $httpBackend.expectGET('/pools/default/buckets/default').respond(200)
    service.tryToGetDefaultBucketInfo();
    $httpBackend.flush();
  });
});