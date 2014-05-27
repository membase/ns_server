describe("wizard.Controller", function () {
  var $scope;
  var authService;

  beforeEach(angular.mock.module('wizard'));
  beforeEach(angular.mock.module('auth.service'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    authService = $injector.get('auth.service');

    $scope = $rootScope.$new();
    $controller('wizard.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.modelAuthService).toBe(authService.model);
  });
});