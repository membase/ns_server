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
    expect(service.model.bucketConf).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectPOST('/pools/default/buckets','authType=sasl&name=default&saslPassword=&bucketType=membase&evictionPolicy=valueOnly&replicaNumber=1&threadsNumber=8&ramQuotaMB=0&flushEnabled=0&replicaIndex=0&otherBucketsRamQuotaMB=0').respond(200);
    service.postBuckets();
    $httpBackend.flush();
    $httpBackend.expectPOST('/pools/default/buckets?ignore_warnings=1&just_validate=1','authType=sasl&name=default&saslPassword=&bucketType=membase&evictionPolicy=valueOnly&replicaNumber=1&threadsNumber=8&ramQuotaMB=0&flushEnabled=0&replicaIndex=0&otherBucketsRamQuotaMB=0').respond(200);
    service.postBuckets(true);
    $httpBackend.flush();
  });
});