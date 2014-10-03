describe("mnAdminSettingsClusterService", function () {
  var $httpBackend;
  var mnAdminSettingsClusterService;

  beforeEach(angular.mock.module('mnAdminSettingsClusterService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnAdminSettingsClusterService = $injector.get('mnAdminSettingsClusterService');
  }));
});