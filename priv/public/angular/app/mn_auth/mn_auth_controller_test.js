describe("mnAuthController", function () {
  var $scope;
  var $httpBackend;

  beforeEach(angular.mock.module('mnAuth'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    $httpBackend.whenGET('/pools').respond(200);

    $scope = $rootScope.$new();
    $controller('mnAuthController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.loginFailed).toBe(false);
    expect($scope.submit).toEqual(jasmine.any(Function));
  });

  it('should leave flag loginFailed as it is if login success', function () {
    $scope.submit();
    $httpBackend.expectPOST('/uilogin').respond(200);
    $httpBackend.flush();
    $scope.$apply();
    expect($scope.loginFailed).toBe(false);
  });

  it('should change flag loginFailed on true if login failed', function () {
    $scope.submit();
    $httpBackend.expectPOST('/uilogin').respond(400);
    $httpBackend.flush();
    expect($scope.loginFailed).toBe(true);
  });
});