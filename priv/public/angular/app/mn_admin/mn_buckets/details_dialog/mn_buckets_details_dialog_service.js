angular.module('mnBucketsDetailsDialogService').factory('mnBucketsDetailsDialogService',
  function (mnHttp, $q, mnBytesToMBFilter, mnPoolDefault, mnServersService, bucketsFormConfiguration, mnBucketsDetailsService) {

    var mnBucketsDetailsDialogService = {};

    mnBucketsDetailsDialogService.getNewBucketConf = function () {
      return $q.all([
        mnServersService.getNodes(),
        mnPoolDefault.get()
      ]).then(function (resp) {
        var activeServersLength = resp[0].active.length;
        var totals = resp[1].storageTotals;
        var bucketConf = _.clone(bucketsFormConfiguration);
        bucketConf.isNew = true;
        bucketConf.ramQuotaMB = mnBytesToMBFilter(Math.floor((totals.ram.quotaTotal - totals.ram.quotaUsed) / activeServersLength));
        return bucketConf;
      });
    };

    mnBucketsDetailsDialogService.reviewBucketConf = function (bucketDetails) {
      return mnBucketsDetailsService.doGetDetails(bucketDetails).then(function (resp) {
        var bucketConf = resp.data;
        bucketConf.ramQuotaMB = mnBytesToMBFilter(bucketConf.quota.rawRAM);
        bucketConf.isDefault = bucketConf.name === 'default';
        bucketConf.flushEnabled = +bucketDetails.flushEnabled;
        return bucketConf;
      });
    };

    mnBucketsDetailsDialogService.postBuckets = function (data) {
      return mnHttp({
        data: data,
        method: 'POST',
        url: data.uri
      });
    };

    return mnBucketsDetailsDialogService;
  });