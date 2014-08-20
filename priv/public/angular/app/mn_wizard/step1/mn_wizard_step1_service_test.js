describe("mnWizardStep1Service", function () {
  var $httpBackend;
  var $timeout;
  var mnWizardStep1Service;

  beforeEach(angular.mock.module('mnWizardStep1Service'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnWizardStep1Service = $injector.get('mnWizardStep1Service');
  }));

  it('should be properly initialized', function () {
    expect(mnWizardStep1Service.postHostname).toEqual(jasmine.any(Function));
    expect(mnWizardStep1Service.getSelfConfig).toEqual(jasmine.any(Function));
    expect(mnWizardStep1Service.model).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectGET('/nodes/self').respond({otpNode: 'n_1@127.0.0.1'});
    mnWizardStep1Service.getSelfConfig();
    $httpBackend.flush();
    $httpBackend.expectPOST('/node/controller/rename', 'hostname=127.0.0.1').respond(200);
    mnWizardStep1Service.postHostname();
    $httpBackend.flush();
  });
});