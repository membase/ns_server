describe("mnAuthService", function () {
  var $httpBackend;
  var $state;
  var createAuthService;
  var mnAuthService;

  beforeEach(angular.mock.module('mnAuthService'));
  beforeEach(angular.mock.module('ui.router'));
  beforeEach(angular.mock.module(function ($stateProvider) {
    $stateProvider
      .state('auth', {})
      .state('app', {})
      .state('app.overview', {
        authenticate: true
      })
      .state('wizard', {
        authenticate: false
      })
      .state('wizard.welcome', {
        authenticate: false
      });
  }));

  beforeEach(inject(function ($injector) {

    $state = $injector.get('$state');
    $httpBackend = $injector.get('$httpBackend');
    mnAuthService = $injector.get('mnAuthService');

    $httpBackend.whenGET('/angular/auth/auth.html').respond(200)
  }));

  function expectPoolsWith(data) {
    $httpBackend.expectGET('/pools').respond(200, data);
    mnAuthService.entryPoint();
    $httpBackend.flush();
  }
  function simulateLoggedIn() {
    expectPoolsWith({isAdminCreds: true, pools: [{uri:"pools/zombie"}]});
  }
  function simulateNotLoggedIn() {
    expectPoolsWith({isAdminCreds: false, pools: [{uri:"pools/zombie"}]});
  }
  function simulateNotInit() {
    expectPoolsWith({isAdminCreds: false, pools: []});
  }

  it('should be properly initialized', function () {
    expect(mnAuthService.model.isAuth).toBeFalsy();
  });

  it('should login if user recently did it', function () {
    simulateLoggedIn();
    expect($state.current.name).toEqual('app.overview');
    expect(mnAuthService.model.isAuth).toBeTruthy();
  });

  it('should redirect to auth page if user not logged in', function () {
    simulateNotLoggedIn();
    expect($state.current.name).toEqual('auth');
    expect(mnAuthService.model.isAuth).toBeFalsy();
  });

  it('should redirect to auth page if user try to open protected page', function () {
    simulateNotLoggedIn();
    $state.transitionTo('app.overview');
    expect($state.current.name).toEqual('auth');
  });

  it('should redirect to app if logged in', function () {
    simulateLoggedIn();
    $state.transitionTo('auth');
    expect($state.current.name).toEqual('app.overview');
  });

  it('should redirect to wizard if cluster not initialized', function () {
    simulateNotInit();
    expect($state.current.name).toEqual('wizard.welcome');
  });

  it('should redirect to app if manually login', function () {
    simulateNotLoggedIn();
    $httpBackend.expectPOST('/uilogin').respond(200);
    $httpBackend.expectGET('/pools').respond(200, {isAdminCreds: true, pools: [{uri:"pools/zombie"}]});
    mnAuthService.manualLogin({username: 'yarrr', password: 'hey-ho'});
    $httpBackend.flush();

    expect($state.current.name).toEqual('app.overview');
    expect(mnAuthService.model.isAuth).toBeTruthy();
  });

  it('should stay on auth screen if manually login is failed', function () {
    simulateNotLoggedIn();
    $httpBackend.expectPOST('/uilogin').respond(400);
    mnAuthService.manualLogin({username: 'yarrr', password: 'hey-ho'});
    $httpBackend.flush();
    expect($state.current.name).toEqual('auth');
    expect(mnAuthService.model.isAuth).toBeFalsy();
  });

  it('should logout', function () {
    simulateLoggedIn();
    $httpBackend.expectPOST('/uilogout').respond(200);
    mnAuthService.manualLogout();
    $httpBackend.flush();
    expect($state.current.name).toEqual('auth');
    expect(mnAuthService.isAuth).toBeFalsy();
  });

});