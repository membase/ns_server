angular.module('app', [
  'mnAdmin',
  'mnAuth',
  'mnWizard',
  'mnExceptionReporter'
]).run(function ($rootScope, $state, $urlRouter, mnPools, $uibModalStack, $window, $exceptionHandler) {
  var originalOnerror = $window.onerror;
  $window.onerror = function (message, url, lineNumber, columnNumber, exception) {
    $exceptionHandler({
      message: message,
      fileName: url,
      lineNumber: lineNumber,
      columnNumber: columnNumber,
      stack: exception.stack
    });
    originalOnerror && originalOnerror.apply($window, Array.prototype.slice.call(arguments));
  };
  $rootScope.$on('$stateChangeError', function (event, toState, toParams, fromState, fromParams, error) {
    $exceptionHandler(error);
  });
  $rootScope.$on('$stateChangeStart', function (event, toState) {
    if ($uibModalStack.getTop()) {
      event.preventDefault();
    }
    mnPools.get().then(function (pools) {
      if (pools.isAuthenticated) {
        var required = (toState.data && toState.data.required) || {};
        var isOnlyForAdmin = (required.admin && pools.isROAdminCreds);
        var isOnlyForEnterprise = (required.enterprise && !pools.isEnterprise);
        if (isOnlyForAdmin || isOnlyForEnterprise) {
          event.preventDefault();
          return $state.go('app.admin.overview');
        }
      }
    });
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