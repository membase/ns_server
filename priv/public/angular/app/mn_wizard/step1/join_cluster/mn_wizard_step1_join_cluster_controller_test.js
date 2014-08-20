describe("mnWizardStep1JoinClusterController", function () {
  var $scope;
  var mnWizardStep1JoinClusterService;
  var mnWizardStep1Service;

  beforeEach(angular.mock.module('mnWizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    mnWizardStep1Service = $injector.get('mnWizardStep1Service');
    mnWizardStep1JoinClusterService = $injector.get('mnWizardStep1JoinClusterService');

    spyOn(mnWizardStep1JoinClusterService, 'populateModel');

    $scope = $rootScope.$new();
    $controller('mnWizardStep1JoinClusterController', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.mnWizardStep1JoinClusterServiceModel).toBe(mnWizardStep1JoinClusterService.model);
  });

  it('should send configuration to populateModel', function () {
    mnWizardStep1Service.model.nodeConfig = undefined;
    $scope.$apply();
    expect(mnWizardStep1JoinClusterService.populateModel.calls.mostRecent().args).toEqual([undefined, undefined, jasmine.any(Object)]);
    mnWizardStep1Service.model.nodeConfig = {storageTotals: {ram: {total: 100, quotaTotal: 100}}};
    $scope.$apply();
    expect(mnWizardStep1JoinClusterService.populateModel.calls.mostRecent().args).toEqual([{ total : 100, quotaTotal : 100 }, undefined, jasmine.any(Object)]);
  });
});