describe("wizard.step1.Controller", function () {
  var step1Service;
  var diskStorageService;
  var joinClusterService;
  var $httpBackend;
  var $scope;

  beforeEach(angular.mock.module('wizard'));
  beforeEach(angular.mock.module('auth.service'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    var $state = $injector.get('$state');
    step1Service = $injector.get('wizard.step1.service');
    joinClusterService = $injector.get('wizard.step1.joinCluster.service');
    $scope = $rootScope.$new();

    spyOn($state, 'transitionTo');

    $controller('wizard.step1.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    $httpBackend.expectGET('/nodes/self').respond(200);
    expect($scope.spinner).toBe(true);
    expect($scope.modelStep1Service).toBe(step1Service.model);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
    $httpBackend.flush();
    expect($scope.spinner).toBe(false);
  });

  it('should send configuration to the server on submit', function () {
    $httpBackend.expectGET('/nodes/self').respond(200);
    $httpBackend.flush();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(200);
    $httpBackend.expectPOST('/pools/default').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();
  });

  it('should try to join to the cluster if appropriate flag was chosen', function () {
    $httpBackend.expectGET('/nodes/self').respond(200);
    $httpBackend.flush();

    joinClusterService.model.joinCluster = 'ok';

    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(200);
    $httpBackend.expectPOST('/node/controller/doJoinCluster').respond(200);
    $httpBackend.expectPOST('/uilogin').respond(400);

    $scope.onSubmit();
    $httpBackend.flush();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();
  });

  it('should stop sending requests if one of them has failed', function () {
    $httpBackend.expectGET('/nodes/self').respond(200);
    $httpBackend.flush();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(400);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($scope.spinner).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    $scope.onSubmit();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(400, []);
    $httpBackend.flush();
    expect($scope.spinner).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    $scope.onSubmit();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(200);
    $httpBackend.expectPOST('/pools/default').respond(400, {errors: {}});
    $httpBackend.flush();
    expect($scope.spinner).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    joinClusterService.model.joinCluster = 'ok';

    $scope.onSubmit();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(200);
    $httpBackend.expectPOST('/node/controller/doJoinCluster').respond(400);
    $httpBackend.flush();
    expect($scope.spinner).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

  });

});