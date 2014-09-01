describe("mnAuthService", function () {
  var $httpBackend;
  var $state;
  var $location;
  var createAuthService;
  var mnAuthService;

  beforeEach(angular.mock.module('mnAuthService'));
  beforeEach(angular.mock.module('mnAuth'));
  beforeEach(angular.mock.module('ui.router'));
  beforeEach(angular.mock.module(function ($stateProvider) {
    $stateProvider
      .state('admin', {})
      .state('admin.overview', {
        url: '/overview',
        authenticate: true
      })
      .state('admin.servers', {
        url: '/servers',
        authenticate: true
      })
      .state('wizard', {
        abstract: true,
        authenticate: false
      })
      .state('wizard.welcome', {
        authenticate: false
      });
  }));

  beforeEach(inject(function ($injector) {

    $state = $injector.get('$state');
    $httpBackend = $injector.get('$httpBackend');
    $location = $injector.get('$location');
    mnAuthService = $injector.get('mnAuthService');
    $rootScope = $injector.get('$rootScope');

    $httpBackend.whenGET('mn_auth/mn_auth.html').respond(200)
  }));
  function go(name) {
    $state.go(name);
    $rootScope.$apply();
  }

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
    expect($state.current.name).toEqual('admin.overview');
    expect(mnAuthService.model.isAuth).toBeTruthy();
  });

  it('should redirect to auth page if user not logged in', function () {
    simulateNotLoggedIn();
    expect($state.current.name).toEqual('auth');
    expect(mnAuthService.model.isAuth).toBeFalsy();
  });

  it('should redirect to auth page if user try to open protected page', function () {
    simulateNotLoggedIn();
    go('admin.overview')
    expect($state.current.name).toEqual('auth');
  });

  it('should redirect to app if logged in', function () {
    simulateLoggedIn();
    go('auth');
    expect($state.current.name).toEqual('admin.overview');
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

    expect($state.current.name).toEqual('admin.overview');
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

  it('should stay on same authenticated page', function () {
    simulateLoggedIn();
    go('admin.servers');
    simulateLoggedIn();
    expect($state.current.name).toEqual('admin.servers');
  });

  it('should logout', function () {
    simulateLoggedIn();
    $httpBackend.expectPOST('/uilogout').respond(200);
    mnAuthService.manualLogout();
    $httpBackend.flush();
    expect($state.current.name).toEqual('auth');
    expect(mnAuthService.isAuth).toBeFalsy();
  });

  it('should logout if response status is 401', function () {
    simulateNotLoggedIn();
    $httpBackend.expectPOST('/uilogin').respond(200);
    $httpBackend.expectGET('/pools').respond(401, {isAdminCreds: true, pools: [{uri:"pools/zombie"}]});
    mnAuthService.manualLogin({username: 'yarrr', password: 'hey-ho'});
    $httpBackend.expectPOST('/uilogout').respond(200);
    $httpBackend.flush();

    expect($state.current.name).toEqual('auth');
    expect(mnAuthService.isAuth).toBeFalsy();
  });

});