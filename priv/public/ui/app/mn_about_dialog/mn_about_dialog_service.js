(function () {
  "use strict";

  angular
    .module("mnAboutDialogService", [
      "mnHttp",
      "mnBucketsService",
      "mnPools",
      "ui.bootstrap",
      "mnFilters",
      "mnPoolDefault"
    ])
    .factory("mnAboutDialogService", mnAboutDialogFactory);

  function mnAboutDialogFactory(mnHttp, $q, $uibModal, mnPools, mnBucketsService, mnIntegerToStringFilter, mnPoolDefault) {
    var mnAboutDialogService = {
      getState: getState,
      showAboutDialog: showAboutDialog
    };

    return mnAboutDialogService;

    function showAboutDialog() {
      $uibModal.open({
        templateUrl: 'app/mn_about_dialog/mn_about_dialog.html',
        controller: "mnAboutDialogController as aboutDialogCtl"
      });
    }

    function getState() {
      return mnPools.getFresh().then(function (pools) {
        if (pools.isAuthenticated) {
          return $q.all([
            mnPoolDefault.get(),
            mnBucketsService.getBucketsByType()
          ]).then(function (resp) {
            var buckets = resp[1];
            var poolDefault = resp[0];
            var bucketsCount = buckets.length;
            if (bucketsCount >= 100) {
              bucketsCount = 99;
            }

            var memcachedBucketsCount = buckets.byType.memcached.length;
            var membaseBucketsCount = buckets.byType.membase.length;

            if (memcachedBucketsCount >= 0x10) {
              memcachedBucketsCount = 0xf;
            }
            if (membaseBucketsCount >= 0x10){
              membaseBucketsCount = 0x0f;
            }

            var date = (new Date());

            var magicString = [
              mnIntegerToStringFilter(0x100 + poolDefault.nodes.length, 16).slice(1)
                + mnIntegerToStringFilter(date.getMonth()+1, 16),
              mnIntegerToStringFilter(100 + bucketsCount, 10).slice(1)
                + mnIntegerToStringFilter(memcachedBucketsCount, 16),
              mnIntegerToStringFilter(membaseBucketsCount, 16)
                + date.getDate()
            ];
            return {
              clusterStateId: magicString.join('-'),
              implementationVersion: pools.implementationVersion
            };
          });
        } else {
          return mnHttp({
            url: "/versions",
            method: "GET"
          }).then(function (resp) {
            return resp.data;
          });
        }
      });
    }
  }
})();
