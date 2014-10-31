angular.module('mnHttp').factory('mnHttp',
  function ($http) {
    function mnHttp(config) {
      switch (config.method.toLowerCase()) {
        case 'post':
          if (!config.notForm) {
            config.headers = {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'};
          } else {
            delete config.notForm;
          }

          config.data = _.serializeData(config.data);
        break;
      }
      return $http(config);
    }
    function createShortMethods(names) {
      _.each(arguments, function (name) {
        mnHttp[name] = function (url, config) {
          return mnHttp(_.extend(config || {}, {
            method: name,
            url: url
          }));
        };
      });
    }
    function createShortMethodsWithData(name) {
      _.each(arguments, function (name) {
        mnHttp[name] = function (url, data, config) {
          return mnHttp(_.extend(config || {}, {
            method: name,
            url: url,
            data: data
          }));
        };
      });
    }

    createShortMethods('get', 'delete', 'head', 'jsonp');
    createShortMethodsWithData('post', 'put');
    return mnHttp;
  });
