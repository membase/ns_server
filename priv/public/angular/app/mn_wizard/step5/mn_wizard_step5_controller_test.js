describe("mnWizardStep5Controller", function () {
  var mnWizardStep5Service;
  var mnWizardStep2Service;
  var $httpBackend;
  var $scope;
  var $state;

  beforeEach(angular.mock.module('mnWizard'));
  beforeEach(angular.mock.module('mnAuth'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    var $state = $injector.get('$state');
    $httpBackend = $injector.get('$httpBackend');

    mnWizardStep5Service = $injector.get('mnWizardStep5Service');
    mnWizardStep2Service = $injector.get('mnWizardStep2Service');
    $scope = $rootScope.$new();
    $scope.form = {};
    $scope.form.$setValidity = function () {};

    spyOn($state, 'go');

    $controller('mnWizardStep5Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.viewLoading).toBe(false);
    expect($scope.mnWizardStep5ServiceModel).toBe(mnWizardStep5Service.model);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
  });

  it('should properly send requests', function () {
    $httpBackend.expectPOST('/settings/web', 'password=&port=SAME&username=Administrator').respond(200);
    $httpBackend.expectPOST('/uilogin').respond(200);
    $httpBackend.expectGET('/pools').respond(200);
    $httpBackend.expectPOST('/pools/default/buckets').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
  });

  it('should install sample buckets if needed', function () {
    mnWizardStep2Service.model.selected = {name: 'some'};
    $httpBackend.expectPOST('/settings/web', 'password=&port=SAME&username=Administrator').respond(200);
    $httpBackend.expectPOST('/uilogin').respond(200);
    $httpBackend.expectGET('/pools').respond(200);
    $httpBackend.expectPOST('/pools/default/buckets').respond(200);
    $httpBackend.expectPOST('/sampleBuckets/install').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
  });

});