angular.module('mnHttp', []);
angular.module('mnHelper', [
  'ui.router'
]);
angular.module('mnBarUsage', []);
angular.module('mnFocus', []);
angular.module('mnSpinner', []);
angular.module('mnPlot', []);
angular.module('mnVerticalBar', []);

angular.module('mnFilters', []);

angular.module('mnPoolDefault', [
  'mnHttp',
  'mnPools'
]);
angular.module('mnTasksDetails', [
  'mnHttp'
]);
angular.module('mnPools', [
  'mnHttp'
]);

angular.module('mnWizard', [
  'mnAuthService',
  'mnServersService',
  'mnHelper',
  'ui.router',
  'mnWizardStep1Service',
  'mnWizardStep2Service',
  'mnWizardStep3Service',
  'mnWizardStep4Service',
  'mnWizardStep5Service'
]);
angular.module('mnWizardStep1Service', [
  'mnHttp'
]);
angular.module('mnWizardStep2Service', [
  'mnHttp'
]);
angular.module('mnWizardStep3Service', [
  'mnHttp',
  'mnWizardStep1Service',
  'mnWizardStep2Service'
]);
angular.module('mnWizardStep4Service', [
  'mnHttp'
]);
angular.module('mnWizardStep5Service', [
  'mnHttp'
]);


angular.module('mnAuthService', [
  'mnHttp'
]);
angular.module('mnAuth', [
  'mnAuthService',
  'mnHelper'
]);


angular.module('mnAdmin', [
  'mnTasksDetails',
  'mnAuthService',
  'mnHelper',
  'ui.router'
]);


angular.module('mnSettingsCluster', [
  'mnSettingsClusterService',
  'mnHelper'
]);
angular.module('mnSettingsClusterService', [
  'mnHttp'
]);
angular.module('mnSettingsAutoFailoverService', [
  'mnHttp'
]);


angular.module('mnServers', [
  'mnPoolDefault',
  'ui.router',
  'ui.bootstrap',
  'mnServersListItemDetailsService',
  'mnSettingsAutoFailoverService',
  'mnServersService',
  'mnHelper'
]);
angular.module('mnServersService', [
  'mnTasksDetails',
  'mnPoolDefault',
  'mnHelper',
  'mnHttp'
]);
angular.module('mnServersListItemDetailsService', [
  'mnTasksDetails',
  'mnHttp'
]);


angular.module('mnOverview', [
  'mnOverviewService'
]);
angular.module('mnOverviewService', [
  'mnPoolDefault',
  'mnHttp'
]);


angular.module('mnBucketsService', [
  'mnHttp'
]);


angular.module('app', [
  'mnFilters',

  'mnHttp',
  'mnHelper',
  'mnBarUsage',
  'mnFocus',
  'mnSpinner',
  'mnPlot',
  'mnVerticalBar',

  'mnPoolDefault',
  'mnTasksDetails',
  'mnPools',

  'ui.router',
  'ui.bootstrap',

  'mnWizard',
  'mnAuth',
  'mnAdmin',
  'mnSettingsCluster',
  'mnServers',
  'mnOverview',
  'mnBucketsService'


]).run(function ($rootScope, $state, $urlRouter, mnPools) {
  mnPools.get().then(function (pools) {
    $rootScope.$on('$stateChangeStart', function (event, current) {
      if (!current.notAuthenticate && !pools.isAuthenticated) {
        event.preventDefault();
        $state.go('app.auth');
      }

      if (current.name == 'app.auth') {
        if (pools.isInitialized) {
          if (pools.isAuthenticated) {
            event.preventDefault();
            $state.go('app.admin.overview');
          }
        } else {
          event.preventDefault();
          $state.go('app.wizard.welcome');
        }
      }
    });
    $urlRouter.listen();
    $urlRouter.sync();
  });
});