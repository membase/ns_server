angular.module('mnWizardStep3Service').factory('mnWizardStep3Service',
  function (mnHttp, mnWizardStep2Service, mnWizardStep1Service, mnBytesToMBFilter, mnCountFilter, mnFormatMemSizeFilter) {

    var mnWizardStep3Service = {};

    var defaultBucketConf = {
      authType: 'sasl',
      name: 'default',
      saslPassword: '',
      bucketType: 'membase',
      evictionPolicy: 'valueOnly',
      replicaNumber: "1",
      replicaIndex: "0",
      threadsNumber: "3",
      flushEnabled: "0",
      ramQuotaMB: "0"
    };

    var bucketRequestUrl;

    mnWizardStep3Service.getBucketConf = function () {
      return mnHttp({
        method: 'GET',
        url: '/pools/default/buckets/default'
      }).then(function (resp) {
        var data = resp.data;
        var bucketConf = _.pick(data, _.keys(defaultBucketConf));
        bucketConf.isDefault = true;
        bucketConf.ramQuotaMB = mnBytesToMBFilter(resp.data.quota.rawRAM);
        return bucketConf;
      }, function () {
        var bucketConf = _.clone(defaultBucketConf);
        bucketConf.isDefault = false;
        bucketConf.ramQuotaMB = mnWizardStep1Service.getDynamicRamQuota() - mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota())
        return bucketConf;
      }).then(function (bucketConf) {
        bucketConf.otherBucketsRamQuotaMB = mnBytesToMBFilter(mnWizardStep2Service.getSampleBucketsRAMQuota());
        return bucketConf;
      })
    };

    function onResult(resp) {
      var result = resp.data;
      if (!result) {
        return;
      }
      var ramSummary = result.summaries.ramSummary;
      var options = {
        topRight: {
          name: 'Cluster quota',
          value: mnFormatMemSizeFilter(ramSummary.total)
        },
        items: [{
          name: 'Other Buckets',
          value: ramSummary.otherBuckets,
          itemStyle: {'background-color': '#00BCE9', 'z-index': '2'},
          labelStyle: {'color': '#1878a2', 'text-align': 'left'}
        }, {
          name: 'This Bucket',
          value: ramSummary.thisAlloc,
          itemStyle: {'background-color': '#7EDB49', 'z-index': '1'},
          labelStyle: {'color': '#409f05', 'text-align': 'center'}
        }, {
          name: 'Free',
          value: ramSummary.total - ramSummary.otherBuckets - ramSummary.thisAlloc,
          itemStyle: {'background-color': '#E1E2E3'},
          labelStyle: {'color': '#444245', 'text-align': 'right'}
        }],
        markers: []
      };

      if (options.items[2].value < 0) {
        options.items[1].value = ramSummary.total - ramSummary.otherBuckets;
        options.items[2] = {
          name: 'Overcommitted',
          value: ramSummary.otherBuckets + ramSummary.thisAlloc - ramSummary.total,
          itemStyle: {'background-color': '#F40015'},
          labelStyle: {'color': '#e43a1b'}
        };
        options.markers.push({
          value: ramSummary.total,
          itemStyle: {'background-color': '#444245'}
        });
        options.markers.push({
          value: ramSummary.otherBuckets + ramSummary.thisAlloc,
          itemStyle: {'background-color': 'red'}
        });
        options.topLeft = {
          name: 'Total Allocated',
          value: mnFormatMemSizeFilter(ramSummary.otherBuckets + ramSummary.thisAlloc),
          itemStyle: {'color': '#e43a1b'}
        };
      }

      return {
        totalBucketSize: mnBytesToMBFilter(ramSummary.thisAlloc * ramSummary.nodesCount),
        nodeCount: mnCountFilter(ramSummary.nodesCount, 'node'),
        perNodeMegs: ramSummary.perNodeMegs,
        guageConfig: options,
        errors: result.errors
      };
    }

     mnWizardStep3Service.postBuckets = function (httpParams) {
      httpParams.url = httpParams.data.isDefault ? '/pools/default/buckets/default' : '/pools/default/buckets';
      httpParams.method = 'POST';
      return mnHttp(httpParams).then(onResult, onResult);
    };

    return mnWizardStep3Service;
  });