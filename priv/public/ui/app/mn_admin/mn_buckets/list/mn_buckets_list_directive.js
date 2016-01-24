(function () {
  "use strict";

  angular
    .module('mnBuckets')
    .directive('mnBucketsList', mnBucketsList);

  function mnBucketsList(mnHelper) {
    var mnBucketsListDirective = {
      restrict: 'A',
      scope: {
        buckets: '='
      },
      isolate: false,
      templateUrl: 'app/mn_admin/mn_buckets/list/mn_buckets_list.html',
      controller: controller,
      controllerAs: "bucketsListCtl",
      bindToController: true
    };

    return mnBucketsListDirective;

    function controller($scope) {
      var vm = this;
      mnHelper.initializeDetailsHashObserver(vm, 'openedBucket', 'app.admin.buckets');
    }
  }
})();
