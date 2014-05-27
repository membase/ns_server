describe("wizard.step5.service", function () {
  var $httpBackend;
  var $timeout;
  var service;

  beforeEach(angular.mock.module('wizard'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    service = $injector.get('wizard.step5.service');
  }));

  it('should be properly initialized', function () {
    expect(service.resetUserCreds).toEqual(jasmine.any(Function));
    expect(service.postAuth).toEqual(jasmine.any(Function));
    expect(service.model).toEqual(jasmine.any(Object));
    expect(service.model.user).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectPOST('/settings/web', 'port=SAME&username=Administrator&password=' , {"Content-Type":"application/x-www-form-urlencoded; charset=UTF-8","Accept":"application/json, text/plain, */*"}).respond(200);
    service.postAuth();
    $httpBackend.flush();
  });
});