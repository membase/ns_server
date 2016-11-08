(function () {
  "use strict";

  angular.module('mnLostConnection', [
    'mnLostConnectionService',
    'mnHelper'
  ]).config(mnLostConnectionConfig);

  function mnLostConnectionConfig($httpProvider) {
    $httpProvider.interceptors.push(['$q', '$injector', interceptorOfErrConnectionRefused]);
  }

  function interceptorOfErrConnectionRefused($q, $injector) {
      return {
        responseError: function (rejection) {
          if (rejection.status <= 0 && rejection.config.timeout &&
              rejection.config.timeout.$$state && rejection.config.timeout.$$state.status === 0) {
            //rejection caused not by us () in case status of $$state is 0
            $injector.get("mnLostConnectionService").activate();
          } else {
            $injector.get("mnLostConnectionService").deactivate();
          }
          return $q.reject(rejection);
        }
      };
    }

})();
