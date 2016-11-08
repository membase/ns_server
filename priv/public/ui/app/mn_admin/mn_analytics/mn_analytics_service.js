(function () {
  "use strict";

  angular
    .module('mnAnalyticsService', [
      'mnBucketsService',
      'mnServersService',
      'mnFilters'
    ])
    .factory('mnAnalyticsService', mnAnalyticsServiceFactory);

  function mnAnalyticsServiceFactory($http, $q, mnBucketsService, mnServersService, mnCloneOnlyDataFilter, mnFormatQuantityFilter, mnParseHttpDateFilter, timeUnitToSeconds) {
    var mnAnalyticsService = {
      getStats: getStats,
      doGetStats: doGetStats,
      prepareNodesList: prepareNodesList
    };

    return mnAnalyticsService;

    function restoreOpsBlock(prevSamples, samples, keepCount) {
      var prevTS = prevSamples.timestamp;
      if (samples.timestamp && samples.timestamp.length == 0) {
        // server was unable to return any data for this "kind" of
        // stats
        if (prevSamples && prevSamples.timestamp && prevSamples.timestamp.length > 0) {
          return prevSamples;
        }
        return samples;
      }
      if (prevTS == undefined ||
          prevTS.length == 0 ||
          prevTS[prevTS.length-1] != samples.timestamp[0]) {
        return samples;
      }
      var newSamples = {};
      for (var keyName in samples) {
        var ps = prevSamples[keyName];
        if (!ps) {
          ps = [];
          ps.length = keepCount;
        }
        newSamples[keyName] = ps.concat(samples[keyName].slice(1)).slice(-keepCount);
      }
      return newSamples;
    }
    function maybeApplyDelta(prevValue, value) {
      var stats = value.stats;
      var prevStats = prevValue.stats || {};
      for (var kind in stats) {
        var newSamples = restoreOpsBlock(prevStats[kind],
                                         stats[kind],
                                         value.samplesCount);
        stats[kind] = newSamples;
      }
      return value;
    }
    function prepareNodesList(params) {
      return mnServersService.getNodes().then(function (nodes) {
        var rv = {};
        rv.nodesNames = _(nodes.active).filter(function (node) {
          return !(node.clusterMembership === 'inactiveFailed') && !(node.status === 'unhealthy');
        }).pluck("hostname").value();
        rv.nodesNames.unshift("All Server Nodes (" + rv.nodesNames.length + ")");
        rv.nodesNames.selected = params.statsHostname || rv.nodesNames[0];
        return rv;
      });
    }
    function getStats(params) {
      var isSpecificStat = !!params.$stateParams.specificStat;
      return mnAnalyticsService.doGetStats(params).then(function (resp) {
        var queries = [
          $q.when(resp)
        ];
        queries.push(isSpecificStat ? $q.when({
          data: resp.data.directory.value,
          origTitle: resp.data.directory.origTitle
        }) : getStatsDirectory(resp.data.directory.url));

        return $q.all(queries).then(function (data) {
          return prepareAnaliticsState(data, params);
        });
      }, function (resp) {
        switch (resp.status) {
          case 0:
          case -1: return $q.reject(resp);
          default: return $q.when({isEmptyState: true});
        }
      });
    }
    function doGetStats(params, mnHttpParams) {
      var reqParams = {
        zoom: params.$stateParams.zoom,
        bucket: params.$stateParams.analyticsBucket
      };
      if (params.$stateParams.specificStat) {
        reqParams.statName = params.$stateParams.specificStat;
      } else {
        reqParams.node = params.$stateParams.statsHostname;
      }
      if (params.previousResult && !params.previousResult.isEmptyState) {
        reqParams.haveTStamp = params.previousResult.stats.lastTStamp;
      }
      return $http({
        url: '/_uistats',
        method: 'GET',
        params: reqParams,
        mnHttp: mnHttpParams
      });
    }
    function getStatsDirectory(url) {
      return $http({
        url: url,
        method: 'GET'
      });
    }
    function prepareAnaliticsState(data, params) {
      var stats = mnCloneOnlyDataFilter(data[0].data);
      var statDesc = mnCloneOnlyDataFilter(data[1].data);
      var samples = {};
      var rv = {};
      if (params.previousResult && !params.previousResult.isEmptyState) {
        stats = maybeApplyDelta(params.previousResult.stats, stats);
      }

      angular.forEach(stats.stats, function (subSamples, subName) {
        var timestamps = subSamples.timestamp;
        for (var k in subSamples) {
          if (k == "timestamp") {
            continue;
          }
          samples[k] = subSamples[k];
          samples[k].timestamps = timestamps;
        }
      });

      stats.serverDate = mnParseHttpDateFilter(data[0].headers('date')).valueOf();
      stats.clientDate = (new Date()).valueOf();

      var statsByName = {};
      var breakInterval = stats.interval * 2.5;
      var timeOffset = stats.clientDate - stats.serverDate;
      var zoomMillis = timeUnitToSeconds[params.$stateParams.zoom] * 1000;

      angular.forEach(statDesc.blocks, function (block, index) {
        block.withTotal = block.columns && block.columns[block.columns.length - 1] === "Total";
        angular.forEach(block.stats, function (info) {
          var sample = samples[info.name];
          statsByName[info.name] = info;
          info.config = {
            data: sample || [],
            breakInterval: breakInterval,
            timeOffset: timeOffset,
            now: stats.clientDate,
            zoomMillis: zoomMillis,
            timestamp: sample && sample.timestamps || stats.stats[stats.mainStatsBlock].timestamp,
            maxY: info.maxY,
            isBytes: info.isBytes,
            value: !sample ? 'N/A' : mnFormatQuantityFilter(sample[sample.length - 1], info.isBytes ? 1024 : 1000)
          };
        });
      });

      rv.isSpecificStats = !!params.$stateParams.specificStat;

      rv.statsByName = statsByName;
      rv.statsDirectoryBlocks = statDesc.blocks;
      rv.stats = stats;
      rv.origTitle = data[1].origTitle;

      return rv;
    }
  }
})();
