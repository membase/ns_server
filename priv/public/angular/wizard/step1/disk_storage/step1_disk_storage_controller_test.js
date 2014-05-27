describe("wizard.step1.diskStorage.Controller", function () {
  var $scope;
  var step1DiskStorageService;
  var step1Service;

  beforeEach(angular.mock.module('wizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    step1Service = $injector.get('wizard.step1.service');
    step1DiskStorageService = $injector.get('wizard.step1.diskStorage.service');

    spyOn(step1DiskStorageService, 'lookup').and.returnValue({
      "path": "/dev",
      "sizeKBytes": 3014292,
      "usagePercent": 1
    });

    spyOn(step1DiskStorageService, 'populateModel');

    $scope = $rootScope.$new();
    $controller('wizard.step1.diskStorage.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.modelDiskStorageService).toBe(step1DiskStorageService.model);
  });

  it('should calculate total db and index path', function () {
    $scope.$apply();
    expect($scope.dbPathTotal).toBe('2 GB');
    expect($scope.indexPathTotal).toBe('2 GB');
  });

  it('should send configuration to populateModel', function () {
    step1Service.model.nodeConfig = undefined;
    $scope.$apply();
    expect(step1DiskStorageService.populateModel.calls.mostRecent().args).toEqual([undefined, undefined, jasmine.any(Object)]);
    step1Service.model.nodeConfig = {'os': 'hey', storage: {hdd: ['hello']}, availableStorage: {hdd: 'there'}};
    $scope.$apply();
    expect(step1DiskStorageService.populateModel.calls.mostRecent().args).toEqual([{os: 'hey', hddStorage: 'hello', availableStorage: 'there'}, undefined, jasmine.any(Object)]);
  });
});