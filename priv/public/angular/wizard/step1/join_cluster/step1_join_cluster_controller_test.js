describe("wizard.step1.joinCluster.Controller", function () {
  var $scope;
  var step1JoinClusterService;
  var step1Service;

  beforeEach(angular.mock.module('wizard'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    step1Service = $injector.get('wizard.step1.service');
    step1JoinClusterService = $injector.get('wizard.step1.joinCluster.service');

    spyOn(step1JoinClusterService, 'populateModel');

    $scope = $rootScope.$new();
    $controller('wizard.step1.joinCluster.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.modelJoinClusterService).toBe(step1JoinClusterService.model);
    expect($scope.focusMe).toBe(true);
  });

  it('should send configuration to populateModel', function () {
    step1Service.model.nodeConfig = undefined;
    $scope.$apply();
    expect(step1JoinClusterService.populateModel.calls.mostRecent().args).toEqual([undefined, undefined, jasmine.any(Object)]);
    step1Service.model.nodeConfig = {storageTotals: {ram: {total: 100, quotaTotal: 100}}};
    $scope.$apply();
    expect(step1JoinClusterService.populateModel.calls.mostRecent().args).toEqual([{ total : 100, quotaTotal : 100 }, undefined, jasmine.any(Object)]);
  });
});