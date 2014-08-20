describe("mnAdminController", function () {
  var $scope;
  var $state;
  var mnAuthService;
  var mnAdminService;

  beforeEach(angular.mock.module('mnAdmin'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $state = {current: {name: "default"}};
    mnAuthService = $injector.get('mnAuthService');
    mnAdminService = $injector.get('mnAdminService');

    spyOn(mnAuthService, 'entryPoint');
    spyOn(mnAdminService, 'runDefaultPoolsDetailsLoop');

    $scope = $rootScope.$new();

    $controller('mnAdminController', {'$scope': $scope, '$state': $state});
  }));

  it('should be properly initialized', function () {
    expect($scope.$state).toBeDefined();
    expect($scope.Math).toBeDefined();
    expect($scope._).toBeDefined();
    expect($scope.logout).toBeDefined(jasmine.any(Function));
  });

  it('should call runDefaultPoolsDetailsLoop with params if isAuth and defaultPoolUri are truly', function () {
    mnAuthService.model.isAuth = false;
    mnAuthService.model.defaultPoolUri = false;
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    mnAuthService.model.isAuth = true;
    mnAuthService.model.defaultPoolUri = false;
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    mnAuthService.model.isAuth = false;
    mnAuthService.model.defaultPoolUri = 'some/one';
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    mnAuthService.model.isAuth = true;
    mnAuthService.model.defaultPoolUri = 'some/one';
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(2);
    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.mostRecent().args).toEqual([jasmine.any(Object), undefined, jasmine.any(Object)]);
  });

  it('should recalculate params if state is changed', function () {
    mnAuthService.model.isAuth = true;
    mnAuthService.model.defaultPoolUri = 'some/one';
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    $state.current.name = "default";
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(1);

    $state.current.name = "app.overview";
    $scope.$apply();

    expect(mnAdminService.runDefaultPoolsDetailsLoop.calls.count()).toBe(2);
  });

});