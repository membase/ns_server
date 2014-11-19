angular.module('mnHttp').factory('mnHttp',
  function ($http) {
    // This is an atered version of the jQuery.param()
    // https://github.com/jquery/jquery/blob/master/src/serialize.js
    function serializeData(data) {
      if (angular.isString(data)) {
        return data;
      }
      if (!angular.isObject(data)) {
        return data == null ? "" : data.toString();
      }
      var rv = [];
      var name;
      for (name in data) {
        if (data.hasOwnProperty(name)) {
          var value = data[name];
          rv.push(encodeURIComponent(name) + "=" + encodeURIComponent(value == null ? "" : value));
        }
      }

      return rv.sort().join("&").replace(/%20/g, "+");
    }
    function mnHttp(config) {
      switch (config.method.toLowerCase()) {
        case 'post':
          if (!config.notForm) {
            config.headers = {'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8'};
          } else {
            delete config.notForm;
          }

          config.data = serializeData(config.data);
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
