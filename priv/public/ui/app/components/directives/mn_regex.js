(function () {
  "use strict";

  angular
    .module('mnRegex', [
      'mnContenteditable',
      'mnFilters',
      'mnPromiseHelper'
    ])
    .directive('mnRegex', mnRegexDirective)
    .directive('mnRegexTestKey', mnRegexTestKeyDirective)
    .factory('mnRegexService', mnRegexFactory);

  function mnRegexFactory($http, getStringBytesFilter, mnPromiseHelper, $q) {
    var properties = {
      hightlightTestKey: null,
      testKey: null,
      filterExpression: null,
      filterExpressionError: null,
      dynamicSpinner: null,
      isSucceeded: null
    };
    var mnRegexService = {
      doValidateOnOverLimit: doValidateOnOverLimit,
      handleValidateRegex: handleValidateRegex,
      validateRegex: validateRegex,
      getProperties: getProperties,
      setProperty: setProperty
    };

    return mnRegexService;

    function setProperty(key, value) {
      properties[key] = value;
    }
    function getProperties() {
      return properties;
    }
    function doValidateOnOverLimit(text) {
      return getStringBytesFilter(text) > 250;
    }
    function sanitize(html) {
      return angular.element('<pre/>').text(html).html();
    }
    function handleValidateRegex(scope) {
      return mnPromiseHelper(scope, mnRegexService.validateRegex(properties.filterExpression, properties.testKey))
        .catchErrors(function (data) {
          properties.filterExpressionError = data;
        })
        .showSpinner(function (showOrHide) {
          properties.dynamicSpinner = showOrHide;
        }, 500, scope)
        .onSuccess(function (result) {
          properties.hightlightTestKey = !!result;
          properties.isSucceeded = !!result;
          if (result) {
            properties.testKey = result;
          }
        })
        .cancelOnScopeDestroy();
    }
    function validateRegex(regex, testKey) {
      if (mnRegexService.doValidateOnOverLimit(regex)) {
        return $q.reject('Regex should not have size more than 250 bytes');
      }
      if (mnRegexService.doValidateOnOverLimit(testKey)) {
        return $q.reject('Test key should not have size more than 250 bytes');
      }
      return $http({
        method: 'POST',
        mnHttp: {
          cancelPrevious: true
        },
        data: {
          expression: regex,
          keys: JSON.stringify([testKey])
        },
        transformResponse: function (data) {
          //angular expect response in JSON format
          //but server returns with text message in case of error
          var resp;

          try {
            resp = JSON.parse(data);
          } catch (e) {
            resp = data;
          }

          return resp;
        },
        url: '/_goxdcr/regexpValidation'
      }).then(function (resp) {
        var result = "";
        angular.forEach(resp.data, function (pairs, key) {
          if (key === "") {
            return;
          }
          var fullSetOfPairs = [];
          _.sortBy(pairs, 'startIndex');
          if (pairs[0] && pairs[0].startIndex != 0) {
            fullSetOfPairs.push({
              startIndex: 0,
              endIndex: pairs[0].startIndex
            });
          }
          angular.forEach(pairs, function (pair, index) {
            if (pair.endIndex !== pair.startIndex) {
              pair.backlight = true;
              fullSetOfPairs.push(pair);
            }
            var next = pairs[index + 1];
            if (next) {
              if (pair.endIndex !== next.startIndex) {
                fullSetOfPairs.push({
                  startIndex: pair.endIndex,
                  endIndex: next.startIndex
                });
              }
            } else {
              fullSetOfPairs.push({
                startIndex: pair.endIndex,
                endIndex: key.length
              });
            }
          });
          angular.forEach(fullSetOfPairs, function (pair, index) {
            var textPart = key.substring(pair.startIndex, pair.endIndex);
            textPart = sanitize(textPart);
            if (pair.backlight) {
              result += '<span>' + textPart + '</span>';
            } else {
              result += textPart;
            }
          });
        });
        return result;
      });
    }
  }


  function mnRegexTestKeyDirective(mnRegexService, $window) {

    var mnRegexTestKey = {
      restrict: 'A',
      priority: 10,
      scope: {},
      require: '?ngModel',
      link: link
    }

    return mnRegexTestKey;

    function link(scope, element, attrs, ngModel) {
      if (!ngModel) {
        return;
      }

      element.on('focus', function () {
        mnRegexService.setProperty("hightlightTestKey", false);
      });

      element.on('blur', function () {
        //clean new line
        var value = element.text();
        element.empty().text(value);
        var current = mnRegexService.getProperties().testKey;
        if (!mnRegexService.doValidateOnOverLimit(current)) {
          $window.localStorage.setItem('mn_xdcr_testKeys', JSON.stringify([current]));
        }
        mnRegexService.handleValidateRegex(scope);
      });
    }
  }

  function mnRegexDirective($sce, $window, mnRegexService) {
    var mnRegex = {
      restrict: 'A',
      priority: 10, //in order to handle in after mn-contenteditable
      scope: {},
      require: '?ngModel',
      link: link
    };

    return mnRegex

    function link(scope, element, attrs, ngModel) {
      if (!ngModel) {
        return;
      }

      element.on('blur', function () {
        //clean new line
        var value = element.text();
        element.empty().text(value);
      });

      var prev;
      element.on('keyup', function () {
        var current = mnRegexService.getProperties().filterExpression;
        if (current === prev) {
          return;
        }
        prev = current;
        if (!mnRegexService.doValidateOnOverLimit(current)) {
          $window.localStorage.setItem('mn_xdcr_regex', current);
        }
        mnRegexService.setProperty("hightlightTestKey", false);
        mnRegexService.handleValidateRegex(scope);
      });
    }
  }
})();
