describe("index.Controller", function () {
  var $scope;
  var authService;
  var $templateCache;
  var createController;
  var $http;
  var $state;
  var $location;

  beforeEach(angular.mock.module('ui.router', function ($stateProvider) {
    $stateProvider.state('test', {url: '/test'}).state('test2', {url: '/test2'});
  }));
  beforeEach(angular.mock.module('index'));
  beforeEach(angular.mock.module('auth.service'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $http = $injector.get('$http');
    $state = $injector.get('$state');
    authService = $injector.get('auth.service');
    $templateCache = $injector.get('$templateCache');
    $location = $injector.get('$location');

    $scope = $rootScope.$new();

    createController = function createControlle() {
      return $controller('index.Controller', {'$scope': $scope});
    };
  }));

  it('should be properly initialized', function () {
    expect(angularTemplatesList).toEqual(jasmine.any(Object));
    spyOn(authService, 'entryPoint');
    createController();
    expect(authService.entryPoint.calls.count()).toBe(1);
  });

  it('should preload templates with caching', function () {
    angularTemplatesList = ["hellow", "there"];
    spyOn($http, 'get');
    createController();

    expect($http.get.calls.count()).toBe(2);
    expect($http.get.calls.argsFor(0)[1].cache).toBe($templateCache);
    expect($http.get.calls.argsFor(0)[0]).toBe("/angular/hellow");
  });

  it('should keeping hash params beetween state transitions', function () {
    $location.search({hellow: 'there'});
    $state.transitionTo('test');
    $scope.$apply();
    $state.transitionTo('test2');
    $scope.$apply();
    expect($location.search()).toEqual({hellow: 'there'});
  });
});