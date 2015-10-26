angular.module('mnRegex', [
  'mnContenteditable',
  'mnFilters',
  'mnPromiseHelper'
]).directive('mnRegex', function ($sce, $window, mnRegexService) {

  return {
    restrict: 'A',
    priority: 10, //in order to handle in after mn-contenteditable
    scope: {
      mnRegex: "="
    },
    require: '?ngModel',
    link: function(scope, element, attrs, ngModel) {
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
        var current = scope.mnRegex.filterExpression;
        if (current === prev) {
          return;
        }
        prev = current;
        if (!mnRegexService.doValidateOnOverLimit(current)) {
          $window.localStorage.setItem('mn_xdcr_regex', current);
        }
        scope.mnRegex.hightlightTestKey = false;
        mnRegexService.handleValidateRegex(scope, scope.mnRegex);
      });
    }
  };
}).directive('mnRegexTestKey', function (mnRegexService, $window) {

  return {
    restrict: 'A',
    priority: 10,
    scope: {
      mnRegexTestKey: "="
    },
    require: '?ngModel',
    link: function (scope, element, attrs, ngModel) {
      if (!ngModel) {
        return;
      }

      element.on('focus', function () {
        scope.mnRegexTestKey.hightlightTestKey = false;
      });

      element.on('blur', function () {
        //clean new line
        var value = element.text();
        element.empty().text(value);
        var current = scope.mnRegexTestKey.testKey;
        if (!mnRegexService.doValidateOnOverLimit(current)) {
          $window.localStorage.setItem('mn_xdcr_testKeys', JSON.stringify([current]));
        }
        mnRegexService.handleValidateRegex(scope, scope.mnRegexTestKey);
      });
    }
  };
}).factory('mnRegexService', function (mnHttp, getStringBytesFilter, mnPromiseHelper, $q) {
  var mnRegexService = {};

  mnRegexService.doValidateOnOverLimit = function (text) {
    return getStringBytesFilter(text) > 250;
  };

  function sanitize(html) {
    return angular.element('<pre/>').text(html).html();
  }

  mnRegexService.handleValidateRegex = function (scope, mnRegexScope) {
    return mnPromiseHelper(scope, mnRegexService.validateRegex(mnRegexScope.filterExpression, mnRegexScope.testKey))
      .catchErrors(function (data) {
        mnRegexScope.filterExpressionError = data;
      })
      .showSpinner(function (showOrHide) {
        mnRegexScope.dynamicSpinner = showOrHide;
      }, 500, scope)
      .onSuccess(function (result) {
        mnRegexScope.hightlightTestKey = !!result;
        mnRegexScope.isSucceeded = !!result;
        if (result) {
          mnRegexScope.testKey = result;
        }
      })
      .cancelOnScopeDestroy();
  };

  mnRegexService.validateRegex = function (regex, testKey) {
    if (mnRegexService.doValidateOnOverLimit(regex)) {
      return $q.reject('Regex should not have size more than 250 bytes');
    }
    if (mnRegexService.doValidateOnOverLimit(testKey)) {
      return $q.reject('Test key should not have size more than 250 bytes');
    }
    return mnHttp({
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
  };

  return mnRegexService;
});