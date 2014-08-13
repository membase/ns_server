describe("wizard.step4.Controller", function () {
  var step4Service;
  var $httpBackend;
  var $scope;
  var $state;

  beforeEach(angular.mock.module('wizard'));
  beforeEach(angular.mock.module('auth'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    step4Service = $injector.get('wizard.step4.service');
    $scope = $rootScope.$new();
    $scope.form = {};
    $state = $injector.get('$state');

    spyOn($state, 'transitionTo');

    $controller('wizard.step4.Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.focusMe).toBe(true);
    expect($scope.modelStep4Service).toBe(step4Service.model);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
  });

  it('should not send requests if form fields are invalid or spinner is shown', function () {
    $scope.form.$invalid = true;
    $scope.onSubmit();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();
    $scope.form.$invalid = false;
    $scope.spinner = true;
    $scope.onSubmit();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();
  });

  it('should send stats onSubmit', function () {
    $httpBackend.expectPOST('/settings/stats').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($scope.spinner).toBe(false);
    expect($state.transitionTo.calls.count()).toBe(1);
  });

  it('should send email onSubmit if email exist', function () {
    $scope.modelStep4Service.register.email = 'my@email.com';
    $httpBackend.expectJSONP('http://ph.couchbase.net/email?callback=JSON_CALLBACK&email=my@email.com&firstname=&lastname=&company=&version=unknown').respond(200);
    $httpBackend.expectPOST('/settings/stats').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($scope.spinner).toBe(false);
  });
});