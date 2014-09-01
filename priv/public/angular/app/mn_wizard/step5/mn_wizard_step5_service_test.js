describe("mnWizardStep5Service", function () {
  var $httpBackend;
  var mnWizardStep5Service;

  beforeEach(angular.mock.module('mnWizard'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnWizardStep5Service = $injector.get('mnWizardStep5Service');
  }));

  it('should be properly initialized', function () {
    expect(mnWizardStep5Service.resetUserCreds).toEqual(jasmine.any(Function));
    expect(mnWizardStep5Service.postAuth).toEqual(jasmine.any(Function));
    expect(mnWizardStep5Service.model).toEqual(jasmine.any(Object));
    expect(mnWizardStep5Service.model.user).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectPOST('/settings/web', 'password=&port=SAME&username=Administrator' , {"Content-Type":"application/x-www-form-urlencoded; charset=UTF-8","Accept":"application/json, text/plain, */*"}).respond(200);
    mnWizardStep5Service.postAuth();
    $httpBackend.flush();
  });
});