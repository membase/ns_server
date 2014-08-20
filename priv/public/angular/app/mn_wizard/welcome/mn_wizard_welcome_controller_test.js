describe("mnWizardWelcomeController", function () {
  var $scope;

  beforeEach(angular.mock.module('mnWizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');

    $scope = $rootScope.$new();
    $controller('mnWizardWelcomeController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.showAboutDialog).toEqual(jasmine.any(Function));
  });
});