angular.module('mnWizard', [
  'mnWizardStep1Service',
  'mnWizardStep2Service',
  'mnWizardStep3Service',
  'mnWizardStep4Service',
  'mnWizardStep5Service',
  'mnAuth',
  'ui.router'
]);

angular.module('mnWizardStep1Service', ['mnAdminServersService']);
angular.module('mnWizardStep2Service', []);
angular.module('mnWizardStep3Service', []);
angular.module('mnWizardStep4Service', []);
angular.module('mnWizardStep5Service', []);

angular.module('mnHttp', []);
angular.module('mnPoolDetails', []);
angular.module('mnTasksDetails', []);
angular.module('mnHelper', []);
angular.module('mnBarUsage', []);
angular.module('mnFocus', []);
angular.module('mnSpinner', []);
angular.module('mnPlot', []);
angular.module('mnPrettyVersionFilter', []);

angular.module('mnAuthService', ['ui.router']);
angular.module('mnAuth', ['mnAuthService']);

angular.module('mnAdmin', [
  'mnAuthService',
  'mnAdminService',
  'mnAdminOverviewService',
  'mnAdminOverview',
  'mnAdminBucketsService',
  'mnAdminBuckets',
  'mnAdminServersService',
  'mnAdminServers',
  'mnAdminSettingsCluster',
  'mnAdminSettingsClusterService'
]);
angular.module('mnAdminService', ['mnAuthService']);
angular.module('mnDateService', []);

angular.module('mnAdminOverviewService', []);
angular.module('mnAdminBucketsService', []);
angular.module('mnAdminBuckets', []);
angular.module('mnAdminOverview', [
  'mnAdminOverviewService',
  'mnAdminBucketsService',
  'mnDateService'
]);

angular.module('mnAdminServersService', ['mnAdminService']);
angular.module('mnAdminServersListItemDetailsService', []);

angular.module('mnAdminServers', [
  'mnAdminService',
  'mnAdminServersService',
  'ui.router',
  'mnAdminServersListItemDetailsService',
  'mnAdminSettingsAutoFailoverService'
]);
angular.module('mnAdminSettingsCluster', ['mnAdminSettingsClusterService']);
angular.module('mnAdminSettingsClusterService', []);
angular.module('mnAdminSettingsAutoFailoverService', []);

angular.module('app', [
  'mnAuthService',
  'mnPoolDetails',
  'mnTasksDetails',
  'ui.bootstrap',
  'mnWizard',
  'mnHelper',
  'mnHttp',
  'mnAuth',
  'mnAdmin',
  'mnBarUsage',
  'mnFocus',
  'mnSpinner',
  'mnPlot',
  'mnVerticalBar',
  'mnPrettyVersionFilter'
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