(function () {
  "use strict";

  angular
    .module('app')
    .config(appConfig);

  function appConfig($httpProvider, $stateProvider, $urlRouterProvider, $uibModalProvider, $transitionsProvider) {
    $httpProvider.defaults.headers.common['invalid-auth-response'] = 'on';
    $httpProvider.defaults.headers.common['Cache-Control'] = 'no-cache';
    $httpProvider.defaults.headers.common['Pragma'] = 'no-cache';
    $httpProvider.defaults.headers.common['ns-server-ui'] = 'yes';

    $uibModalProvider.options.backdrop = 'static';

    $urlRouterProvider.otherwise('/overview');

    $stateProvider.state('app', {
      url: '?{enableInternalSettings:bool}&{disablePoorMansAlerts:bool}',
      params: {
        enableInternalSettings: {
          value: null,
          squash: true
        },
        disablePoorMansAlerts: {
          value: null,
          squash: true
        }
      },
      abstract: true,
      template: '<div ui-view="" />'
    });

    $transitionsProvider.onBefore({
      from: "app.admin.**",
      to: "app.admin.**"
    }, function ($uibModalStack) {
      return !$uibModalStack.getTop();
    });
    $transitionsProvider.onBefore({
      from: "app.auth",
      to: "app.admin.**"
    }, function (mnPools) {
      return mnPools.get().then(function () {
        return true;
      }, function (resp) {
        switch (resp.status) {
          case 401: return false;
        }
      });
    });
    $transitionsProvider.onBefore({
      from: "app.wizard.**",
      to: "app.auth"
    }, function (mnPools) {
      return mnPools.get().then(function (pools) {
        return pools.isInitialized;
      });
    });
    $transitionsProvider.onBefore({
      from: "app.admin.**",
      to: "app.auth"
    }, function (mnPools) {
      return mnPools.get().then(function () {
        return false;
      }, function (resp) {
        switch (resp.status) {
          case 401: return true;
        }
      });
    });
    $transitionsProvider.onStart({
      to: function (state) {
        return state.data && state.data.permissions;
      }
    }, function ($state, $parse, mnPermissions, $transition$) {
      return mnPermissions.check().then(function() {
        if (!$parse($transition$.to().data.permissions)(mnPermissions.export)) {
          return false;
        }
      });
    });
    $transitionsProvider.onStart({
      to: function (state) {
        return state.data && state.data.compat;
      }
    }, function ($state, $parse, mnPoolDefault, $transition$) {
      return mnPoolDefault.get().then(function() {
        if (!$parse($transition$.to().data.compat)(mnPoolDefault.export.compat)) {
          return false;
        }
      });
    });
    $transitionsProvider.onStart({
      to: function (state) {
        return state.data && state.data.required && state.data.required.enterprise;
      }
    }, function ($state, mnPools) {
      return mnPools.get().then(function (pools) {
        if (!pools.isEnterprise) {
          return false;
        }
      });
    });

    $urlRouterProvider.deferIntercept();
  }
})();
