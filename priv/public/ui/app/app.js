(function () {
  "use strict";

  angular.module('app', [
    'mnAdmin',
    'mnAuth',
    'mnWizard',
    'mnHttp',
    'mnExceptionReporter',
    'ui.bootstrap'
  ]).run(appRun);

  function appRun($rootScope, $state, $urlRouter, mnPools, $uibModalStack, $window, $exceptionHandler, $http, $templateCache, mnPendingQueryKeeper) {
    var originalOnerror = $window.onerror;

    $window.onerror = onError;
    $rootScope.$on('$stateChangeError', onStateChangeError);
    $rootScope.$on('$stateChangeStart', onStateChangeStart);
    $rootScope.$on('$locationChangeSuccess', onLocationChangeSuccess);
    $urlRouter.listen();
    angular.forEach(angularTemplatesList, function (url) {
      $http.get(url, {cache: $templateCache});
    });

    function onError(message, url, lineNumber, columnNumber, exception) {
      $exceptionHandler({
        message: message,
        fileName: url,
        lineNumber: lineNumber,
        columnNumber: columnNumber,
        stack: exception.stack
      });
      originalOnerror && originalOnerror.apply($window, Array.prototype.slice.call(arguments));
    }
    function onStateChangeError(event, toState, toParams, fromState, fromParams, error) {
      $exceptionHandler(error);
    }
    function onStateChangeStart(event, toState, toParams, fromState, fromParams, error) {
      if (fromState.name.indexOf('app.admin') > -1 && toState.name.indexOf('app.admin') > -1) {
        if ($uibModalStack.getTop()) {
          return event.preventDefault();
        }
        mnPools.get().then(function (pools) {
          var required = (toState.data && toState.data.required) || {};
          var isOnlyForAdmin = (required.admin && pools.isROAdminCreds);
          var isOnlyForEnterprise = (required.enterprise && !pools.isEnterprise);
          if (isOnlyForAdmin || isOnlyForEnterprise) {
            event.preventDefault();
            return $state.go('app.admin.overview');
          }
        });
      }
    }
    function onLocationChangeSuccess(event) {
      event.preventDefault();
      mnPools.get().then(function (pools) {
        if (pools.isInitialized) {
          $urlRouter.sync();
        } else {
          $state.go('app.wizard.welcome');
        }
      }, function (resp) {
        switch (resp.status) {
          case 401: return $state.go('app.auth');
        }
      });
    }
  }
})();
