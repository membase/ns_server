angular.module('mnBucketsDetailsDialogService', [
  'mnHttp',
  'mnFilters',
  'mnPoolDefault',
  'mnServersService',
  'mnBucketsDetailsService',
  'mnSettingsAutoCompactionService'
]).factory('mnBucketsDetailsDialogService',
  function (mnHttp, $q, mnBytesToMBFilter, mnCountFilter, mnSettingsAutoCompactionService, mnPoolDefault, mnServersService, bucketsFormConfiguration, mnBucketsDetailsService) {

    var mnBucketsDetailsDialogService = {};

    mnBucketsDetailsDialogService.prepareBucketConfigForSaving = function (bucketConf, autoCompactionSettings) {
      var conf = {};
      angular.forEach(['bucketType', 'ramQuotaMB', 'name', 'evictionPolicy', 'authType', 'saslPassword', 'proxyPort', 'replicaNumber', 'replicaIndex', 'threadsNumber', 'flushEnabled', 'autoCompactionDefined', 'otherBucketsRamQuotaMB'], function (fieldName) {
        if (bucketConf[fieldName] !== undefined) {
          conf[fieldName] = bucketConf[fieldName];
        }
      });
      if (conf.autoCompactionDefined) {
        _.extend(conf, mnSettingsAutoCompactionService.prepareSettingsForSaving(autoCompactionSettings));
      }
      return conf;
    };

    mnBucketsDetailsDialogService.adaptValidationResult = function (result) {
      var ramSummary = result.summaries.ramSummary;

      return {
        totalBucketSize: mnBytesToMBFilter(ramSummary.thisAlloc),
        nodeCount: mnCountFilter(ramSummary.nodesCount, 'node'),
        perNodeMegs: ramSummary.perNodeMegs,
        guageConfig: mnBucketsDetailsService.getBucketRamGuageConfig(ramSummary),
        errors: result.errors
      };
    };

    mnBucketsDetailsDialogService.getNewBucketConf = function () {
      return $q.all([
        mnServersService.getNodes(),
        mnPoolDefault.getFresh()
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
        bucketConf.replicaIndex = bucketConf.replicaIndex ? 1 : 0;
        bucketConf.flushEnabled = (bucketConf.controllers !== undefined && bucketConf.controllers.flush !== undefined) ? 1 : 0;
        return bucketConf;
      });
    };

    mnBucketsDetailsDialogService.postBuckets = function (data, uri) {
      return mnHttp({
        data: data,
        method: 'POST',
        url: uri
      });
    };

    return mnBucketsDetailsDialogService;
  });