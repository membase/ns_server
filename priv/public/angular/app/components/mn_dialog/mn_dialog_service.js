angular.module('mnDialog').factory('mnDialogService',
  function ($http, $templateCache, $compile, $rootScope, $document) {
    var mnDialogService = {};

    mnDialogService.open = function open(options) {

      var $scope = options.scope && options.scope.$new() || $rootScope.$new();
      var bodyElement = angular.element($document[0].body);

      return $http.get(options.template, {
                cache: $templateCache
              }).then(function (response) {
                var tempalte = angular.element(response.data);
                bodyElement.append($compile(tempalte)($scope));
              });
    };

    return mnDialogService;
  });