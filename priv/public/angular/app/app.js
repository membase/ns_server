angular.module('mnWizardStep1Service', []);
angular.module('mnWizardStep1DiskStorageService', []);
angular.module('mnWizardStep1JoinClusterService', []);
angular.module('mnWizardStep2Service', []);
angular.module('mnWizardStep3Service', []);
angular.module('mnWizardStep4Service', []);
angular.module('mnWizardStep5Service', []);

angular.module('mnBarUsage', []);
angular.module('mnDialog', []);
angular.module('mnFocus', []);
angular.module('mnSpinner', []);
angular.module('mnPrettyVersionFilter', []);

angular.module('mnAuthService', ['ui.router']);
angular.module('mnAuth', ['mnAuthService']);

angular.module('mnAdmin', [
  'mnAuthService',
  'mnAdminService',
  'mnAdminOverviewService',
  'mnAdminOverview'
]);
angular.module('mnAdminService', []);
angular.module('mnAdminOverviewService', ['mnAdminService']);
angular.module('mnAdminOverview', ['mnAdminOverviewService']);

angular.module('mnWizard', [
  'mnWizardStep1Service',
  'mnWizardStep1DiskStorageService',
  'mnWizardStep1JoinClusterService',
  'mnWizardStep2Service',
  'mnWizardStep3Service',
  'mnWizardStep4Service',
  'mnWizardStep5Service',
  'mnDialog',
  'ui.router'
]);

angular.module('app', [
  'mnWizard',
  'mnAuth',
  'mnAdmin',
  'mnBarUsage',
  'mnFocus',
  'mnDialog',
  'mnSpinner',
  'mnPrettyVersionFilter'
]).run();