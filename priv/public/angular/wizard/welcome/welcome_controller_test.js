describe("wizard.welcome.Controller", function () {
  var $scope;

  beforeEach(angular.mock.module('wizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');

    $scope = $rootScope.$new();
    $controller('wizard.welcome.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.focusMe).toBe(true);
  });
});