angular.module('app.service', ['auth.service'])
  .factory('app.service',
    ['$http', '$q', '$timeout',
      function ($http, $q, $timeout) {
        var canceler;
        var timeout;
        var scope = {};
        scope.model = {};

        scope.runDefaultPoolsDetailsLoop = function runDefaultPoolsDetailsLoop(params, next) {
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
            scope.model.isEnterprise = details.isEnterprise;
            scope.model.details = details;
            scope.runDefaultPoolsDetailsLoop(params, details);
          });
        }

        return scope;
      }]);
