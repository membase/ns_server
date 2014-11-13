angular.module('mnHttp', []);
angular.module('mnHelper', []);
angular.module('mnBarUsage', []);
angular.module('mnFocus', []);
angular.module('mnSpinner', []);
angular.module('mnPlot', []);
angular.module('mnPrettyVersionFilter', []);
angular.module('mnDateService', []);
angular.module('mnVerticalBar', []);

angular.module('mnPoolDetails', [
  'mnHttp'
]);
angular.module('mnTasksDetails', [
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
  'mnAuthService'
]);


angular.module('mnAdmin', [
  'mnTasksDetails',
  'mnAuthService',
  'ui.router'
]);
angular.module('mnAdminService', [
  'mnHttp'
]);


angular.module('mnAdminSettingsCluster', [
  'mnAdminSettingsClusterService'
]);
angular.module('mnAdminSettingsClusterService', [
  'mnHttp'
]);
angular.module('mnAdminSettingsAutoFailoverService', [
  'mnHttp'
]);


angular.module('mnAdminServers', [
  'mnPoolDetails',
  'ui.router',
  'ui.bootstrap',
  'mnAdminServersListItemDetailsService',
  'mnAdminSettingsAutoFailoverService',
  'mnAdminServersService',
  'mnHelper'
]);
angular.module('mnAdminServersService', [
  'mnAdminService',
  'mnTasksDetails',
  'mnPoolDetails',
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
  'mnPoolDetails',
  'mnDateService',
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
  'mnDateService',
  'mnVerticalBar',

  'mnPoolDetails',
  'mnTasksDetails',

  'ui.router',
  'ui.bootstrap',

  'mnWizard',
  'mnAuth',
  'mnAdmin',
  'mnAdminSettingsCluster',
  'mnAdminServers',
  'mnAdminOverview',
  'mnAdminBucketsService'


]).run(function ($rootScope, $state, $urlRouter, mnAuthService) {
  mnAuthService.getPools().then(function (pools) {
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