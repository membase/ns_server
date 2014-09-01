angular.module('mnDialog').factory('mnDialogService',
  function ($http, $templateCache, $compile, $rootScope, $document) {
    var mnDialogService = {};

    mnDialogService.model = {};
    mnDialogService.model.opened = [];

    mnDialogService.getLastOpened = function () {
      return mnDialogService.model.opened[mnDialogService.model.opened.length - 1]
    };

    mnDialogService.removeLastOpened = function () {
      var element = mnDialogService.model.opened.pop();
      element.scope().$destroy();
      element.remove();
    };

    mnDialogService.open = function open(options) {

      var $scope = options.scope && options.scope.$new() || $rootScope.$new();
      var bodyElement = angular.element($document[0].body);

      return $http.get(options.template, {
                cache: $templateCache
              }).then(function (response) {
                var tempalte = angular.element(response.data);
                var element = $compile(tempalte)($scope);
                mnDialogService.model.opened.push(element);
                bodyElement.append(element);
              });
    };

    return mnDialogService;
  });