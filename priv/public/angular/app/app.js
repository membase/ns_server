angular.module('mnWizardStep1Service', []);
angular.module('mnWizardStep1DiskStorageService', []);
angular.module('mnWizardStep1JoinClusterService', []);
angular.module('mnWizardStep2Service', []);
angular.module('mnWizardStep3Service', []);
angular.module('mnWizardStep4Service', []);
angular.module('mnWizardStep5Service', []);

angular.module('mnDialogs', []);
angular.module('mnHttp', []);
angular.module('mnBarUsage', []);
angular.module('mnDialog', []);
angular.module('mnFocus', []);
angular.module('mnSpinner', []);
angular.module('mnPlot', []);
angular.module('mnPrettyVersionFilter', []);

angular.module('mnAuthService', ['ui.router']);
angular.module('mnAuth', ['mnAuthService']);

angular.module('mnAdmin', [
  'mnDialogs',
  'mnAuthService',
  'mnAdminTasksService',
  'mnAdminService',
  'mnAdminOverviewService',
  'mnAdminOverview',
  'mnAdminBucketsService',
  'mnAdminBuckets',
  'mnAdminServersService',
  'mnAdminServers',
  'mnAdminSettings',
  'mnAdminSettingsService'
]);
angular.module('mnAdminService', ['mnAuthService']);
angular.module('mnDateService', []);

angular.module('mnAdminTasksService', []);

angular.module('mnAdminOverviewService', []);
angular.module('mnAdminBucketsService', []);
angular.module('mnAdminBuckets', []);
angular.module('mnAdminOverview', [
  'mnAdminOverviewService',
  'mnAdminBucketsService',
  'mnDateService'
]);

angular.module('mnAdminServersService', ['mnAdminService']);

angular.module('mnAdminServersAddDialog', []);
angular.module('mnAdminServersListItemService', []);
angular.module('mnAdminServersListItemDetailsService', []);
angular.module('mnAdminServersFailOverDialogService', []);
angular.module('mnAdminServersAddDialogService', []);

angular.module('mnAdminServers', [
  'mnAdminService',
  'mnAdminServersService',
  'mnAdminServersFailOverDialogService',
  'mnAdminServersListItemService',
  'mnDialog',
  'mnAdminTasksService',
  'ui.router',
  'mnAdminServersListItemDetailsService',
  'mnAdminServersAddDialogService',
  'mnAdminSettingsAutoFailoverService'
]);
angular.module('mnAdminSettings', [
  'mnAdminSettingsCluster',
  'mnAdminSettingsClusterService',
  'mnAdminSettingsAutoFailoverService'
]);
angular.module('mnAdminSettingsCluster', [
  'mnAdminSettingsClusterService'
]);

angular.module('mnAdminSettingsService', []);
angular.module('mnAdminSettingsClusterService', [
  'mnAdminService',
  'mnAdminServersService'
]);
angular.module('mnAdminSettingsAutoFailoverService', []);

angular.module('mnWizard', [
  'mnWizardStep1Service',
  'mnWizardStep1DiskStorageService',
  'mnWizardStep1JoinClusterService',
  'mnWizardStep2Service',
  'mnWizardStep3Service',
  'mnWizardStep4Service',
  'mnWizardStep5Service',
  'mnDialog',
  'mnAuth',
  'ui.router'
]);

angular.module('app', [
  'mnAuthService',
  'mnWizard',
  'mnAuth',
  'mnHttp',
  'mnAdmin',
  'mnBarUsage',
  'mnFocus',
  'mnDialog',
  'mnSpinner',
  'mnPlot',
  'mnVerticalBar',
  'mnPrettyVersionFilter'
]).run();