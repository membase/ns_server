describe("appController", function () {
  var $scope;
  var mnAuthService;
  var $templateCache;
  var createController;
  var $http;
  var $state;
  var $location;
  var mnDialogService;

  beforeEach(angular.mock.module('ui.router', function ($stateProvider) {
    $stateProvider.state('test', {url: '/test'}).state('test2', {url: '/test2'});
  }));
  beforeEach(angular.mock.module('app'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $http = $injector.get('$http');
    $state = $injector.get('$state');
    mnAuthService = $injector.get('mnAuthService');
    mnDialogService = $injector.get('mnDialogService');
    $templateCache = $injector.get('$templateCache');
    $location = $injector.get('$location');

    spyOn(mnAuthService, 'entryPoint');
    spyOn($http, 'get');

    $scope = $rootScope.$new();

    createController = function createControlle() {
      return $controller('appController', {'$scope': $scope});
    };
  }));

  it('should be properly initialized', function () {
    expect(angularTemplatesList).toEqual(jasmine.any(Object));
    createController();
    expect($scope.mnDialogService).toBe(mnDialogService);
    expect(mnAuthService.entryPoint.calls.count()).toBe(1);
  });

  it('should preload templates with caching', function () {
    angularTemplatesList = ["hellow", "there"];
    createController();

    expect($http.get.calls.count()).toBe(2);
    expect($http.get.calls.argsFor(0)[1].cache).toBe($templateCache);
    expect($http.get.calls.argsFor(0)[0]).toBe("/angular/hellow");
  });

  it('should keeping hash params beetween state transitions', function () {
    mnAuthService.model.initialized = true;
    createController();
    $location.search({hellow: 'there'});
    $state.go('test');
    $scope.$apply();
    $state.go('test2');
    $scope.$apply();
    expect($state.current.name).toBe('test2');
    expect($location.search()).toEqual({hellow: 'there'});
  });
});