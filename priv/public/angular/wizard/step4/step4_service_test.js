describe("wizard.step4.service", function () {
  var $httpBackend;
  var $timeout;
  var service;

  beforeEach(angular.mock.module('wizard'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    service = $injector.get('wizard.step4.service');
  }));

  it('should be properly initialized', function () {
    expect(service.postEmail).toEqual(jasmine.any(Function));
    expect(service.postStats).toEqual(jasmine.any(Function));
    expect(service.model).toEqual(jasmine.any(Object));
    expect(service.model.sendStats).toBe(true);
    expect(service.model.register).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    service.model.register = {
      version: 'version',
      email: 'my@email.com',
      firstname: 'firstname',
      lastname: 'lastname',
      company: 'company',
      agree: true
    };
    $httpBackend.expectJSONP('http://ph.couchbase.net/email?callback=JSON_CALLBACK&company=company&email=my%40email.com&firstname=firstname&lastname=lastname&version=version').respond(200);
    $httpBackend.expectPOST('/settings/stats').respond(200);
    service.postEmail();
    service.postStats();
    $httpBackend.flush();
  });
});