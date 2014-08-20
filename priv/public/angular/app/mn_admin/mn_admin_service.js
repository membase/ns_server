angular.module('mnAdminService').factory('mnAdminService',
  function ($http, $q, $timeout) {
    var canceler;
    var timeout;
    var mnAdminService = {};
    mnAdminService.model = {};

    mnAdminService.runDefaultPoolsDetailsLoop = function (params, next) {
      canceler && canceler.resolve();
      if (!params) {
        return;
      }
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
        mnAdminService.runDefaultPoolsDetailsLoop(params, details);
      });
    }

    return mnAdminService;
  });
