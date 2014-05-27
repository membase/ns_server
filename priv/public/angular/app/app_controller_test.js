describe("app.controller", function () {
  var $scope;
  var $state;
  var authService;
  var appService;

  beforeEach(angular.mock.module('app'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $state = {current: {name: "default"}};
    authService = $injector.get('auth.service');
    appService = $injector.get('app.service');

    spyOn(authService, 'entryPoint');
    spyOn(appService, 'runDefaultPoolsDetailsLoop');

    $scope = $rootScope.$new();

    $controller('app.Controller', {'$scope': $scope, '$state': $state});
  }));

  it('should be properly initialized', function () {
    expect($scope.$state).toBeDefined();
    expect($scope.Math).toBeDefined();
    expect($scope._).toBeDefined();
    expect($scope.logout).toBeDefined(jasmine.any(Function));
  });

  it('should call runDefaultPoolsDetailsLoop with params if isAuth and defaultPoolUri are truly', function () {
    authService.model.isAuth = false;
    authService.model.defaultPoolUri = false;
    $scope.$apply();

    expect(appService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    authService.model.isAuth = true;
    authService.model.defaultPoolUri = false;
    $scope.$apply();

    expect(appService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    authService.model.isAuth = false;
    authService.model.defaultPoolUri = 'some/one';
    $scope.$apply();

    expect(appService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    authService.model.isAuth = true;
    authService.model.defaultPoolUri = 'some/one';
    $scope.$apply();

    expect(appService.runDefaultPoolsDetailsLoop.calls.count()).toBe(2);
    expect(appService.runDefaultPoolsDetailsLoop.calls.mostRecent().args).toEqual([jasmine.any(Object), undefined, jasmine.any(Object)]);
  });

  it('should recalculate params if state is changed', function () {
    authService.model.isAuth = true;
    authService.model.defaultPoolUri = 'some/one';
    $scope.$apply();

    expect(appService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    $state.current.name = "default";
    $scope.$apply();

    expect(appService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    $state.current.name = "app.overview";
    $scope.$apply();

    expect(appService.runDefaultPoolsDetailsLoop.calls.count()).toBe(2);
  });

});