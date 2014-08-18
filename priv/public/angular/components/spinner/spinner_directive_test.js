describe("spinner", function () {
  var $rootScope;
  var $element;
  var $compile;
  var createSpinner;
  var $httpBackend;

  beforeEach(angular.mock.module('spinner'));

  beforeEach(inject(function ($injector) {
    $rootScope = $injector.get('$rootScope');
    $compile = $injector.get('$compile')
    $element = angular.element('<div spinner="spinner" id="spinner">content</div>');

    createSpinner = function createSpinner() {
      $compile($element)($rootScope);
      $rootScope.$apply();
      return $element;
    }
  }));

  it('should be properly initialized', function () {
    var spinner = createSpinner();
    expect(spinner.html()).toEqual('content<div class="spinner ng-scope ng-hide" ng-show="spinner"></div>');
    expect(spinner.hasClass('spinner_wrap')).toBe(true);
  });

});