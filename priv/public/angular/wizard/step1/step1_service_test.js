describe("wizard.step1.service", function () {
  var $httpBackend;
  var $timeout;
  var service;


  beforeEach(angular.mock.module('wizard.step1.service'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    service = $injector.get('wizard.step1.service');
  }));

  it('should be properly initialized', function () {
    expect(service.postHostname).toEqual(jasmine.any(Function));
    expect(service.getSelfConfig).toEqual(jasmine.any(Function));
    expect(service.model).toEqual(jasmine.any(Object));
  });

  it('should be able to send requests', function () {
    $httpBackend.expectGET('/nodes/self').respond({otpNode: 'n_1@127.0.0.1'});
    service.getSelfConfig();
    $httpBackend.flush();
    $httpBackend.expectPOST('/node/controller/rename', 'hostname=127.0.0.1').respond(200);
    service.postHostname();
    $httpBackend.flush();
  });
});