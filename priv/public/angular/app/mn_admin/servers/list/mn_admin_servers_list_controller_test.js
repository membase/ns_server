describe("mnAdminServersListController", function () {
  var $scope;
  var $stateParams;
  var mnAdminServersService;

  beforeEach(angular.mock.module('mnAdminServers'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $stateParams = $injector.get('$stateParams');
    mnAdminServersService = $injector.get('mnAdminServersService');

    $scope = $rootScope.$new();

    $controller('mnAdminServersListController', {'$scope': $scope});
  }));

  it('should be able to switch servers list', function () {
    mnAdminService.model.nodes = {active: 'active', pending: 'pending'};
    $stateParams.list = 'active';
    $scope.$apply();
    expect($scope.nodesList).toEqual('active');
    $stateParams.list = 'pending';
    $scope.$apply();
    expect($scope.nodesList).toEqual('pending');
  });

});