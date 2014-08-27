describe("mnWizardStep4Controller", function () {
  var mnWizardStep4Service;
  var $httpBackend;
  var $scope;
  var $state;

  beforeEach(angular.mock.module('mnWizard'));
  beforeEach(angular.mock.module('mnAuth'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $controller = $injector.get('$controller');
    $httpBackend = $injector.get('$httpBackend');

    mnWizardStep4Service = $injector.get('mnWizardStep4Service');
    $scope = $rootScope.$new();
    $scope.form = {};
    $state = $injector.get('$state');

    spyOn($state, 'transitionTo');

    $controller('mnWizardStep4Controller', {'$scope': $scope});
  }));

  it('should be properly initialized', function () {
    expect($scope.mnWizardStep4ServiceModel).toBe(mnWizardStep4Service.model);
    expect($scope.onSubmit).toEqual(jasmine.any(Function));
    expect($scope.viewLoading).toEqual(undefined);
  });

  it('should not send requests if form fields are invalid or spinner is shown', function () {
    $scope.form.$invalid = true;
    $scope.onSubmit();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();
    $scope.form.$invalid = false;
    $scope.viewLoading = true;
    $scope.onSubmit();
    $httpBackend.verifyNoOutstandingRequest();
    $httpBackend.verifyNoOutstandingExpectation();
  });

  it('should send stats onSubmit', function () {
    $httpBackend.expectPOST('/settings/stats').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($scope.viewLoading).toBe(false);
    expect($state.transitionTo.calls.count()).toBe(1);
  });

  it('should send email onSubmit if email exist', function () {
    $scope.mnWizardStep4ServiceModel.register.email = 'my@email.com';
    $httpBackend.expectJSONP('http://ph.couchbase.net/email?callback=JSON_CALLBACK&company=&email=my%40email.com&firstname=&lastname=&version=unknown').respond(200);
    $httpBackend.expectPOST('/settings/stats').respond(200);
    $scope.onSubmit();
    $httpBackend.flush();
    expect($scope.viewLoading).toBe(false);
  });
});