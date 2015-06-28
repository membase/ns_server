angular.module('app', [
  'mnAdmin',
  'mnAuth',
  'mnWizard'
]).run(function ($rootScope, $state, $urlRouter, mnPools) {
  $rootScope.$on('$stateChangeError', function (event, toState, toParams, fromState, fromParams, error) {
    throw new Error(error.message);
  });
  $rootScope.$on('$locationChangeSuccess', function (event) {
    event.preventDefault();
    mnPools.get().then(function (pools) {
      if (pools.isAuthenticated) {
        $urlRouter.sync();
      } else {
        if (pools.isInitialized) {
          $state.go('app.auth');
        } else {
          $state.go('app.wizard.welcome');
        }
      }
    });
  });
  $urlRouter.listen();
});