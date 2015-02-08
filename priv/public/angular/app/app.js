angular.module('mnHttp', []);
angular.module('mnHelper', [
  'ui.router',
  'mnTasksDetails'
]);
angular.module('mnBarUsage', []);
angular.module('mnWarmupProgress', []);
angular.module('mnFocus', []);
angular.module('mnSpinner', []);
angular.module('mnPlot', []);
angular.module('mnVerticalBar', []);
angular.module('mnBucketsForm', [
  'mnHttp',
  'mnBucketsDetailsService'
]);
angular.module('mnCompaction', [
  'mnHttp'
]);

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
angular.module('mnAlertsService', []);

angular.module('mnWizard', [
  'mnAuthService',
  'mnServersService',
  'mnAlertsService',
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
  'mnAlertsService',
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

angular.module('mnBuckets', [
  'mnHelper',
  'mnBucketsService',
  'mnBucketsDetailsService',
  'mnCompaction'
]);
angular.module('mnBucketsService', [
  'mnHttp'
]);
angular.module('mnBucketsDetailsService', [
  'mnHttp',
  'mnPoolDefault',
  'mnTasksDetails',
  'mnCompaction'
]);
angular.module('mnBucketsDetailsDialogService', [
  'mnHttp',
  'mnPoolDefault',
  'mnServersService',
  'mnBucketsDetailsService'
]);

angular.module('mnViews', [
  'mnViewsService'
]);
angular.module('mnViewsService', [
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
  'mnWarmupProgress',
  'mnCompaction',
  'mnBucketsForm',

  'mnPoolDefault',
  'mnTasksDetails',
  'mnPools',

  'ui.router',
  'ui.bootstrap',
  'ui.select',
  'ngSanitize',

  'mnWizard',
  'mnAuth',
  'mnAdmin',
  'mnSettingsCluster',
  'mnServers',
  'mnOverview',
  'mnBuckets',
  'mnBucketsDetailsDialogService',
  'mnViews'


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