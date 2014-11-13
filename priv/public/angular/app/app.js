angular.module('mnHttp', []);
angular.module('mnHelper', [
  'ui.router'
]);
angular.module('mnBarUsage', []);
angular.module('mnFocus', []);
angular.module('mnSpinner', []);
angular.module('mnPlot', []);
angular.module('mnPrettyVersionFilter', []);
angular.module('mnVerticalBar', []);

angular.module('mnPoolDefault', [
  'mnHttp'
]);
angular.module('mnTasksDetails', [
  'mnHttp'
]);
angular.module('mnPools', [
  'mnHttp'
]);

angular.module('mnWizard', [
  'mnAuthService',
  'mnAdminServersService',
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


angular.module('mnAdminSettingsCluster', [
  'mnAdminSettingsClusterService',
  'mnHelper'
]);
angular.module('mnAdminSettingsClusterService', [
  'mnHttp'
]);
angular.module('mnAdminSettingsAutoFailoverService', [
  'mnHttp'
]);


angular.module('mnAdminServers', [
  'mnPoolDefault',
  'ui.router',
  'ui.bootstrap',
  'mnAdminServersListItemDetailsService',
  'mnAdminSettingsAutoFailoverService',
  'mnAdminServersService',
  'mnHelper'
]);
angular.module('mnAdminServersService', [
  'mnTasksDetails',
  'mnPoolDefault',
  'mnHelper',
  'mnHttp'
]);
angular.module('mnAdminServersListItemDetailsService', [
  'mnTasksDetails',
  'mnHttp'
]);


angular.module('mnAdminOverview', [
  'mnAdminOverviewService'
]);
angular.module('mnAdminOverviewService', [
  'mnPoolDefault',
  'mnHttp'
]);


angular.module('mnAdminBucketsService', [
  'mnHttp'
]);


angular.module('app', [
  'mnHttp',
  'mnHelper',
  'mnBarUsage',
  'mnFocus',
  'mnSpinner',
  'mnPlot',
  'mnPrettyVersionFilter',
  'mnVerticalBar',

  'mnPoolDefault',
  'mnTasksDetails',
  'mnPools',

  'ui.router',
  'ui.bootstrap',

  'mnWizard',
  'mnAuth',
  'mnAdmin',
  'mnAdminSettingsCluster',
  'mnAdminServers',
  'mnAdminOverview',
  'mnAdminBucketsService'


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