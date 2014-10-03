describe("mnAdminSettingsClusterController", function () {
  var $scope;
  var mnAdminSettingsClusterService;
  var promise;

  beforeEach(angular.mock.module('mnAdminSettingsCluster'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    promise = new specRunnerHelper.MockedPromise();
    mnAdminSettingsClusterService = $injector.get('mnAdminSettingsClusterService');

    spyOn(mnAdminSettingsClusterService, 'getRamQuotaTotalPerNodeMegs');
    spyOn(mnAdminSettingsClusterService, 'getVisualSettingsUri');
    spyOn(mnAdminSettingsClusterService, 'getRamTotalPerActiveNode');

    spyOn(mnAdminSettingsClusterService, 'setRamQuotaTotalPerNode');
    spyOn(mnAdminSettingsClusterService, 'setRamTotalPerActiveNodeInMegs');
    spyOn(mnAdminSettingsClusterService, 'setMaxRamPerActiveNodeInMegs');

    spyOn(mnAdminSettingsClusterService, 'getAndSetVisualInternalSettings');
    spyOn(mnAdminSettingsClusterService, 'getAndSetDefaultCertificate').and.returnValue(promise);
    spyOn(mnAdminSettingsClusterService, 'regenerateCertificate').and.returnValue(promise);
    spyOn(mnAdminSettingsClusterService, 'saveVisualInternalSettings').and.returnValue(promise);

    $scope = $rootScope.$new();

    $controller('mnAdminSettingsClusterController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.DVL).toBe(mnAdminSettingsClusterService.model.dataViewLayer);
    expect($scope.DIL).toBe(mnAdminSettingsClusterService.model.dataInputLayer);
    expect($scope.DVL.focusMe).toBe(true);

    expect($scope.toggleCertArea).toBeDefined();
    expect($scope.regenerateCertificate).toBeDefined();
    expect($scope.saveVisualInternalSettings).toBeDefined();

    expect(mnAdminSettingsClusterService.getAndSetDefaultCertificate).toHaveBeenCalled();

    $scope.$apply();

    expect(mnAdminSettingsClusterService.saveVisualInternalSettings).toHaveBeenCalledWith("justValidate");

    expect(mnAdminSettingsClusterService.getRamTotalPerActiveNode).toHaveBeenCalled();
    expect(mnAdminSettingsClusterService.setRamTotalPerActiveNodeInMegs).toHaveBeenCalled();

    expect(mnAdminSettingsClusterService.getRamTotalPerActiveNode).toHaveBeenCalled();
    expect(mnAdminSettingsClusterService.setMaxRamPerActiveNodeInMegs).toHaveBeenCalled();

    expect(mnAdminSettingsClusterService.getRamQuotaTotalPerNodeMegs).toHaveBeenCalled();
    expect(mnAdminSettingsClusterService.setRamQuotaTotalPerNode).toHaveBeenCalled();

    expect(mnAdminSettingsClusterService.getVisualSettingsUri).toHaveBeenCalled();
    expect(mnAdminSettingsClusterService.getAndSetVisualInternalSettings).toHaveBeenCalled();

    $scope.DIL.memoryQuota = 'trigger test';
    $scope.$apply();

    expect(mnAdminSettingsClusterService.saveVisualInternalSettings.calls.count()).toBe(2);
  });

  it('should saveVisualInternalSettings', function () {
    $scope.saveVisualInternalSettings();
    expect(mnAdminSettingsClusterService.saveVisualInternalSettings).toHaveBeenCalled();
  });

  it('should regenerateCertificate', function () {
    $scope.regenerateCertificate();
    expect(mnAdminSettingsClusterService.regenerateCertificate).toHaveBeenCalled();
  });

  it('should toggleCertificateArea', function () {
    $scope.toggleCertArea();
    expect($scope.DVL.toggleCertArea).toBe(true);
    $scope.toggleCertArea();
    expect($scope.DVL.toggleCertArea).toBe(false);
  });
});