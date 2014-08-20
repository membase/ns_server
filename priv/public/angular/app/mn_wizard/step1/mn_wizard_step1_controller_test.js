describe("mnWizardStep1Controller", function () {
  var mnWizardStep1Service;
  var mnWizardStep1DiskStorageService;
  var mnWizardStep1JoinClusterService;
  var $httpBackend;
  var $scope;

  beforeEach(angular.mock.module('mnWizard'));
  beforeEach(angular.mock.module('mnAuthService'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    var $state = $injector.get('$state');
    mnWizardStep1Service = $injector.get('mnWizardStep1Service');
    mnWizardStep1JoinClusterService = $injector.get('mnWizardStep1JoinClusterService');
    $scope = $rootScope.$new();

    spyOn($state, 'transitionTo');

    $controller('mnWizardStep1Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    $httpBackend.expectGET('/nodes/self').respond(200);
    expect($scope.viewLoading).toBe(true);
    expect($scope.mnWizardStep1ServiceModel).toBe(mnWizardStep1Service.model);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
    $httpBackend.flush();
    expect($scope.viewLoading).toBe(false);
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

    mnWizardStep1JoinClusterService.model.joinCluster = 'ok';

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
    expect($scope.viewLoading).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    $scope.onSubmit();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(400, []);
    $httpBackend.flush();
    expect($scope.viewLoading).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    $scope.onSubmit();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(200);
    $httpBackend.expectPOST('/pools/default').respond(400, {errors: {}});
    $httpBackend.flush();
    expect($scope.viewLoading).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

    mnWizardStep1JoinClusterService.model.joinCluster = 'ok';

    $scope.onSubmit();
    $httpBackend.expectPOST('/nodes/self/controller/settings').respond(200);
    $httpBackend.expectPOST('/node/controller/rename').respond(200);
    $httpBackend.expectPOST('/node/controller/doJoinCluster').respond(400);
    $httpBackend.flush();
    expect($scope.viewLoading).toBeFalsy();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();

  });

});