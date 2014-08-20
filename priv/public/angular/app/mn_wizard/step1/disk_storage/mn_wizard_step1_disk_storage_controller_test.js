describe("mnWizardStep1DiskStorageController", function () {
  var $scope;
  var mnWizardStep1DiskStorageService;
  var mnWizardStep1Service;

  beforeEach(angular.mock.module('mnWizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    mnWizardStep1Service = $injector.get('mnWizardStep1Service');
    mnWizardStep1DiskStorageService = $injector.get('mnWizardStep1DiskStorageService');

    spyOn(mnWizardStep1DiskStorageService, 'lookup').and.returnValue({
      "path": "/dev",
      "sizeKBytes": 3014292,
      "usagePercent": 1
    });

    spyOn(mnWizardStep1DiskStorageService, 'populateModel');

    $scope = $rootScope.$new();
    $controller('mnWizardStep1DiskStorageController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.mnWizardStep1DiskStorageServiceModel).toBe(mnWizardStep1DiskStorageService.model);
  });

  it('should calculate total db and index path', function () {
    $scope.$apply();
    expect($scope.dbPathTotal).toBe('2 GB');
    expect($scope.indexPathTotal).toBe('2 GB');
  });

  it('should send configuration to populateModel', function () {
    mnWizardStep1Service.model.nodeConfig = undefined;
    $scope.$apply();
    expect(mnWizardStep1DiskStorageService.populateModel.calls.mostRecent().args).toEqual([undefined, undefined, jasmine.any(Object)]);
    mnWizardStep1Service.model.nodeConfig = {'os': 'hey', storage: {hdd: ['hello']}, availableStorage: {hdd: 'there'}};
    $scope.$apply();
    expect(mnWizardStep1DiskStorageService.populateModel.calls.mostRecent().args).toEqual([{os: 'hey', hddStorage: 'hello', availableStorage: 'there'}, undefined, jasmine.any(Object)]);
  });
});