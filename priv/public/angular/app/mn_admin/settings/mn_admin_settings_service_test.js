describe("mnAdminSettingsService", function () {
  var $httpBackend;
  var mnAdminSettingsService;

  beforeEach(angular.mock.module('mnAdminSettingsService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnAdminSettingsService = $injector.get('mnAdminSettingsService');
  }));
});