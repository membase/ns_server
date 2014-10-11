angular.module('mnHttp').factory('mnHttpService',
  function ($http, $q, $timeout) {

    return function (httpParams) {
      var request;
      var canceler;
      var timeout;
      var period;

      function mnHttpService(additionalHttpParams) {
        canceler && canceler.resolve();
        period && $timeout.cancel(period);

        var params = _.merge(_.clone(httpParams), additionalHttpParams);

        if (!params.url) {
          return;
        }

        canceler = $q.defer();

        if (params.period) {
          period = $timeout(function () {
            mnHttpService(additionalHttpParams);
          }, params.period);
        }
        if (params.keepURL) {
          httpParams.url = params.url;
        }
        if (params.timeout) {
          timeout && $timeout.cancel(timeout);
          timeout = $timeout(canceler.resolve, params.timeout);
        }
        if (params.method === 'POST') {
          params.headers = {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'};
          if (params.data) {
            params.data = _.serializeData(params.data);
          }
        }

        params.timeout = canceler.promise;
        request = $http(params);

        if (params.spinner) {
          params.spinner(true);
          request['finally'](function () {
            params.spinner(false);
          });
        }

        if (params.success) {
          _.each(params.success, function (success) {
            request.success(success);
          });
        }
        if (params.error) {
          _.each(params.error, function (error) {
            request.error(error);
          });
        }

        return request;
      }

      mnHttpService.cancel = function () {
        period && $timeout.cancel(period);
        canceler && canceler.resolve();
        request = null;
        canceler = null;
        timeout = null;
        period = null;
      };

      return mnHttpService;
    };
  });
