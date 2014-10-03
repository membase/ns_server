describe("mnAdminSettingsController", function () {
  var $scope;

  beforeEach(angular.mock.module('mnAdminSettings'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');

    $scope = $rootScope.$new();

    $controller('mnAdminSettingsController', {'$scope': $scope});
  }));

});