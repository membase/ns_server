describe("mnWizardStep4Service", function () {
  var $httpBackend;
  var $timeout;
  var mnWizardStep4Service;

  beforeEach(angular.mock.module('mnWizard'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnWizardStep4Service = $injector.get('mnWizardStep4Service');
  }));

  it('should be properly initialized', function () {
    expect(mnWizardStep4Service.postEmail).toEqual(jasmine.any(Function));
    expect(mnWizardStep4Service.postStats).toEqual(jasmine.any(Function));
    expect(mnWizardStep4Service.model).toEqual(jasmine.any(Object));
    expect(mnWizardStep4Service.model.sendStats).toBe(true);
    expect(mnWizardStep4Service.model.register).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    mnWizardStep4Service.model.register = {
      version: 'version',
      email: 'my@email.com',
      firstname: 'firstname',
      lastname: 'lastname',
      company: 'company',
      agree: true
    };
    $httpBackend.expectJSONP('http://ph.couchbase.net/email?callback=JSON_CALLBACK&company=company&email=my%40email.com&firstname=firstname&lastname=lastname&version=version').respond(200);
    $httpBackend.expectPOST('/settings/stats').respond(200);
    mnWizardStep4Service.postEmail();
    mnWizardStep4Service.postStats();
    $httpBackend.flush();
  });
});