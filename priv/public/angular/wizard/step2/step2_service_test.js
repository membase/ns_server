describe("wizard.step2.service", function () {
  var $httpBackend;
  var $timeout;
  var service;


  beforeEach(angular.mock.module('wizard.step2.service'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    service = $injector.get('wizard.step2.service');
  }));

  it('should be properly initialized', function () {
    expect(service.getSampleBuckets).toEqual(jasmine.any(Function));
    expect(service.installSampleBuckets).toEqual(jasmine.any(Function));
    expect(service.model).toEqual(jasmine.any(Object));
    expect(service.model.selected).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectGET('/sampleBuckets').respond(200);
    service.getSampleBuckets();
    $httpBackend.flush();
    service.model.selected = {some: 123456, buckets: 123456, name: 123456};
    $httpBackend.expectPOST('/sampleBuckets/install', ["some","buckets","name"]).respond(200);
    service.installSampleBuckets();
    $httpBackend.flush();
  });
});