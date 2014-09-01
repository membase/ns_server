angular.module('mnAdminService').factory('mnAdminService',
  function ($http, $q, $timeout, $state, mnAuthService) {
    var canceler;
    var timeout;
    var mnAdminService = {};
    mnAdminService.model = {};

    mnAdminService.stopDefaultPoolsDetailsLoop = function () {
      canceler && canceler.resolve();
    };

    mnAdminService.waitChangeOfPoolsDetailsLoop = function () {
      return $state.current.name === 'admin.overview' ||
             $state.current.name === 'admin.manage_servers' ? 3000 : 20000;
    };

    mnAdminService.runDefaultPoolsDetailsLoop = function (next) {
      mnAdminService.stopDefaultPoolsDetailsLoop();

      if (!(mnAuthService.model.defaultPoolUri && mnAuthService.model.isAuth)) {
        return;
      }

      var params = {
        url: mnAuthService.model.defaultPoolUri,
        params: {waitChange: mnAdminService.waitChangeOfPoolsDetailsLoop()}
      };

      canceler = $q.defer();
      params.timeout = canceler.promise;
      params.method = 'GET';
      params.responseType = 'json';

      if (next && next.etag) {
        timeout && $timeout.cancel(timeout);
        timeout = $timeout(canceler.resolve, 30000); //TODO: add some behaviour for this case
        params.params.etag = next.etag;
      }

      $http(params).success(function (details) {
        if (!details) {
          return;
        }
        mnAdminService.model.isEnterprise = details.isEnterprise;
        mnAdminService.model.details = details;
        mnAdminService.runDefaultPoolsDetailsLoop(details);
      });
    }

    return mnAdminService;
  });
