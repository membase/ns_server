(function () {
  "use strict";

  angular
    .module('app')
    .config(appConfig);

  function appConfig($httpProvider, $stateProvider, $urlRouterProvider, $uibModalProvider, $transitionsProvider, $uibTooltipProvider) {
    $httpProvider.defaults.headers.common['invalid-auth-response'] = 'on';
    $httpProvider.defaults.headers.common['Cache-Control'] = 'no-cache';
    $httpProvider.defaults.headers.common['Pragma'] = 'no-cache';
    $httpProvider.defaults.headers.common['ns-server-ui'] = 'yes';

    $uibModalProvider.options.backdrop = 'static';
    // When using a tooltip in an absolute positioned element,
    // you need tooltip-append-to-body="true" https://github.com/angular-ui/bootstrap/issues/4195
    $uibTooltipProvider.options({
      appendToBody: true,
      placement: "auto right"
    });

    $urlRouterProvider.otherwise(function ($injector, $location) {
      $injector.get("mnPools").get().then(function (pools) {
        if (pools.isInitialized) {
          return $injector.get("$state").go("app.admin.overview");
        }
      });
      return true;
    });

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
      resolve: {
        env: function (mnEnv, $rootScope) {
          return mnEnv.loadEnv().then(function(env) {
            $rootScope.ENV = env;
          });
        }
      },
      template: '<div ui-view=""></div>' +
        '<div ng-show="mnGlobalSpinnerFlag" class="global-spinner"></div>'
    });

    $transitionsProvider.onBefore({
      from: "app.admin.**",
      to: "app.admin.**"
    }, function ($uibModalStack, mnPendingQueryKeeper, $transition$, $rootScope) {
      var isModalOpen = !!$uibModalStack.getTop();
      var toName = $transition$.to().name;
      var fromName = $transition$.from().name;
      if ($rootScope.mnGlobalSpinnerFlag) {
        return false;
      }
      if (!isModalOpen && toName.indexOf(fromName) === -1 && fromName.indexOf(toName) === -1) {
        //cancel tabs specific queries in case toName is not child of fromName and vise versa
        mnPendingQueryKeeper.cancelTabsSpecificQueries();
      }
      return !isModalOpen;
    });
    $transitionsProvider.onBefore({
      from: "app.auth",
      to: "app.admin.**"
    }, function (mnPools, $state) {
      return mnPools.get().then(function (pools) {
        return pools.isInitialized ? true : $state.target("app.wizard.welcome");
      }, function (resp) {
        switch (resp.status) {
          case 401: return false;
        }
      });
    });
    $transitionsProvider.onBefore({
      from: "app.wizard.**",
      to: "app.admin.**"
    }, function (mnPools) {
      return mnPools.get().then(function (pools) {
        return pools.isInitialized;
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
        return !!$parse($transition$.to().data.permissions)(mnPermissions.export);
      });
    });
    $transitionsProvider.onStart({
      to: function (state) {
        return state.data && state.data.compat;
      }
    }, function ($state, $parse, mnPoolDefault, $transition$) {
      return mnPoolDefault.get().then(function() {
        return !!$parse($transition$.to().data.compat)(mnPoolDefault.export.compat);
      });
    });
    $transitionsProvider.onStart({
      to: function (state) {
        return state.data && state.data.ldap;
      }
    }, function ($state, $parse, mnPoolDefault, $transition$) {
      return mnPoolDefault.get().then(function(value) {
        return value.ldapEnabled;
      });
    });
    $transitionsProvider.onStart({
      to: function (state) {
        return state.data && state.data.enterprise;
      }
    }, function ($state, mnPools) {
      return mnPools.get().then(function (pools) {
        return pools.isEnterprise;
      });
    });

    $urlRouterProvider.deferIntercept();
  }
})();
