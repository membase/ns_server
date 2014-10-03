describe("mnSpinnerDirective", function () {
  var createSpinner;

  beforeEach(angular.mock.module('mnSpinner'));

  beforeEach(inject(function ($injector) {
    var $rootScope = $injector.get('$rootScope');
    var $compile = $injector.get('$compile');
    var $element = angular.element('<div mn-spinner-directive="viewLoading"="spinner" id="spinner">content</div>');

    createSpinner = function () {
      $compile($element)($rootScope);
      $rootScope.$apply();
      return $element;
    }
  }));

  it('should be properly initialized', function () {
    var spinner = createSpinner();
    expect(spinner.html()).toEqual('content<div class="spinner ng-scope ng-hide" ng-show="viewLoading"></div>');
    expect(spinner.hasClass('spinner_wrap')).toBe(true);
  });

});