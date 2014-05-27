describe("wizard.step2.Controller", function () {
  var step2Service;
  var $httpBackend;
  var $scope;

  beforeEach(angular.mock.module('wizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    step2Service = $injector.get('wizard.step2.service');
    $scope = $rootScope.$new();

    $controller('wizard.step2.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    $httpBackend.expectGET('/sampleBuckets').respond(200, "hey");
    expect($scope.spinner).toBe(true);
    expect($scope.focusMe).toBe(true);
    expect($scope.modelStep2Service).toBe(step2Service.model);
    $httpBackend.flush();
    expect($scope.spinner).toBe(false);
    expect($scope.sampleBuckets).toBe("hey");
  });

  it('should be properly calculate sampleBucketsRAMQuota', function () {
    $httpBackend.expectGET('/sampleBuckets').respond(200);
    $scope.modelStep2Service.selected = {some: 123456, buckets: 123456, name: 123456};
    $scope.$apply();
    expect($scope.modelStep2Service.sampleBucketsRAMQuota).toBe(370368);
  });

});