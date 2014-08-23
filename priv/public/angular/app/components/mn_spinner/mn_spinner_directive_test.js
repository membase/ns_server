describe("mnSpinnerDirective", function () {
  var $rootScope;
  var $element;
  var $compile;
  var createSpinner;
  var $httpBackend;

  beforeEach(angular.mock.module('mnSpinner'));

  beforeEach(inject(function ($injector) {
    $rootScope = $injector.get('$rootScope');
    $compile = $injector.get('$compile')
    $element = angular.element('<div mn-spinner-directive="spinner" id="spinner">content</div>');

    createSpinner = function () {
      $compile($element)($rootScope);
      $rootScope.$apply();
      return $element;
    }
  }));

  it('should be properly initialized', function () {
    var spinner = createSpinner();
    expect(spinner.html()).toEqual('content<div class="spinner" ng-show="viewLoading"></div>');
    expect(spinner.hasClass('spinner_wrap')).toBe(true);
  });

});