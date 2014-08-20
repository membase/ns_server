describe("mnWizardStep2Controller", function () {
  var mnWizardStep2Service;
  var $httpBackend;
  var $scope;

  beforeEach(angular.mock.module('mnWizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    mnWizardStep2Service = $injector.get('mnWizardStep2Service');
    $scope = $rootScope.$new();

    $controller('mnWizardStep2Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    $httpBackend.expectGET('/sampleBuckets').respond(200, "hey");
    expect($scope.viewLoading).toBe(true);
    expect($scope.mnWizardStep2ServiceModel).toBe(mnWizardStep2Service.model);
    $httpBackend.flush();
    expect($scope.viewLoading).toBe(false);
    expect($scope.sampleBuckets).toBe("hey");
  });

  it('should be properly calculate sampleBucketsRAMQuota', function () {
    $httpBackend.expectGET('/sampleBuckets').respond(200);
    $scope.mnWizardStep2ServiceModel.selected = {some: 123456, buckets: 123456, name: 123456};
    $scope.$apply();
    expect($scope.mnWizardStep2ServiceModel.sampleBucketsRAMQuota).toBe(370368);
  });

});