describe("mnWizardStep2Service", function () {
  var $httpBackend;
  var mnWizardStep2Service;

  beforeEach(angular.mock.module('mnWizardStep2Service'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnWizardStep2Service = $injector.get('mnWizardStep2Service');
  }));

  it('should be properly initialized', function () {
    expect(mnWizardStep2Service.getSampleBuckets).toEqual(jasmine.any(Function));
    expect(mnWizardStep2Service.installSampleBuckets).toEqual(jasmine.any(Function));
    expect(mnWizardStep2Service.model).toEqual(jasmine.any(Object));
    expect(mnWizardStep2Service.model.selected).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectGET('/sampleBuckets').respond(200);
    mnWizardStep2Service.getSampleBuckets();
    $httpBackend.flush();
    mnWizardStep2Service.model.selected = {some: 123456, buckets: 123456, name: 123456};
    $httpBackend.expectPOST('/sampleBuckets/install', ["some","buckets","name"]).respond(200);
    mnWizardStep2Service.installSampleBuckets();
    $httpBackend.flush();
  });
});