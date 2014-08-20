describe("mnWizardController", function () {
  var $scope;
  var mnAuthService;

  beforeEach(angular.mock.module('mnWizard'));
  beforeEach(angular.mock.module('mnAuthService'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    mnAuthService = $injector.get('mnAuthService');

    $scope = $rootScope.$new();
    $controller('mnWizardController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.mnAuthServiceModel).toBe(mnAuthService.model);
  });
});