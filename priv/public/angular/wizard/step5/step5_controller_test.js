describe("wizard.step5.Controller", function () {
  var step5Service;
  var step2Service;
  var $httpBackend;
  var $scope;
  var $state;

  beforeEach(angular.mock.module('wizard'));
  beforeEach(angular.mock.module('auth'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    step5Service = $injector.get('wizard.step5.service');
    step2Service = $injector.get('wizard.step2.service');
    $scope = $rootScope.$new();
    $scope.form = {};
    $scope.form.$setValidity = function () {};

    $controller('wizard.step5.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.focusMe).toBe(true);
    expect($scope.spinner).toBe(undefined);
    expect($scope.modelStep5Service).toBe(step5Service.model);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
  });

  it('should properly send requests', function () {
    $httpBackend.expectPOST('/settings/web', 'port=SAME&username=Administrator&password=').respond(200);
    $httpBackend.expectPOST('/uilogin').respond(200);
    $httpBackend.expectGET('/pools').respond(200);
    $httpBackend.expectPOST('/pools/default/buckets').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
  });

  it('should install sample buckets if needed', function () {
    step2Service.model.selected = {name: 'some'};
    $httpBackend.expectPOST('/settings/web', 'port=SAME&username=Administrator&password=').respond(200);
    $httpBackend.expectPOST('/uilogin').respond(200);
    $httpBackend.expectGET('/pools').respond(200);
    $httpBackend.expectPOST('/pools/default/buckets').respond(200);
    $httpBackend.expectPOST('/sampleBuckets/install').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
  });

});