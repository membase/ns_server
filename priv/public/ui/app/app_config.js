(function () {
  "use strict";

  angular
    .module('app')
    .config(appConfig);

  function appConfig($httpProvider, $stateProvider, $urlRouterProvider, $uibModalProvider) {
    $httpProvider.defaults.headers.common['invalid-auth-response'] = 'on';
    $httpProvider.defaults.headers.common['Cache-Control'] = 'no-cache';
    $httpProvider.defaults.headers.common['Pragma'] = 'no-cache';
    $httpProvider.defaults.headers.common['ns-server-ui'] = 'yes';

    $uibModalProvider.options.backdrop = 'static';

    $stateProvider.state('app', {
      url: '',
      abstract: true,
      template: '<div ui-view="" />',
      resolve: {
        pools: function (mnPools) {
          return mnPools.get();
        }
      }
    });

    $urlRouterProvider.deferIntercept();
    $urlRouterProvider.otherwise('/overview');
  }
})();
