angular.module('mnSettingsNotificationsService', [
  'mnPoolDefault',
  'mnBucketsService',
  'mnPools',
  'mnAnalyticsService',
  'mnViewsListService',
  'mnSettingsClusterService',
  'mnSettingsAutoFailoverService',
  'mnSettingsAutoCompactionService',
  'mnGsiService',
  'mnAuditService',
  'mnFilters',
  'mnPermissions'
]).factory('mnSettingsNotificationsService',
  function ($http, mnPoolDefault, mnBucketsService, mnPools, $q, $window, $rootScope, mnAnalyticsService, mnViewsListService, mnGsiService, mnAuditService, mnMBtoBytesFilter, mnPermissions, mnSettingsClusterService, mnSettingsAutoFailoverService, mnSettingsAutoCompactionService) {
    var mnSettingsNotificationsService = {};

    function sumWithoutNull(array, average) {
      if (!array) {
        return 0;
      }
      array = _.without(array, null);
      if (!array.length) {
        return 0;
      }
      var rv = _.reduce(array, function (memo, num) {
        return memo + num;
      }, 0);
      return average ? rv / array.length : rv;
    }

    function buildPhoneHomeThingy(source) {
      var bucketsList = source[0];
      var perBucketStats = source[1];
      var pools = source[2];
      var poolsDefault = source[3];
      var indexStatus = source[4];
      var auditSettings = source[5];
      var indexSettings = source[6];
      var autoFailoverSettings = source[7];
      var autoCompactionSettings = source[8];

      function getAvgPerItem(items, filter) {
        var avgs = [];
        _.each(items, function (item, key) {
          if (filter(key)) {
            avgs.push(sumWithoutNull(item, true));
          }
        });
        return avgs;
      }
      function precision(val) {
        return Number(val.toFixed(5));
      }

      function getHourFromWeek(value) {
        return value / 11520 * 60;
      }

      function calculateAvgWeekAndHour(stats, name, avg) {
        var weekName = name + "_last_week";
        var hourName = name + "_last_hour";
        if (stats.istats[weekName].length) {
          stats.istats[weekName] = sumWithoutNull(stats.istats[weekName], avg);
          stats.istats[hourName] = getHourFromWeek(stats.istats[weekName]);
          stats.istats[weekName] = precision(stats.istats[weekName]);
          stats.istats[hourName] = precision(stats.istats[hourName]);
        } else {
          stats.istats[weekName] = 0;
          stats.istats[hourName] = 0;
        }
      }

      function setPerBucketStat(stats, name, value) {
        if (value) {
          var weekName = name + "_last_week";
          stats.istats[weekName] = stats.istats[weekName].concat(value);
        }
      }

      var stats = {
        cluster_settings: {},
        version: pools.implementationVersion,
        componentsVersion: pools.componentsVersion,
        uuid: pools.uuid,
        numNodes: poolsDefault.nodes.length, //Total number of nodes
        isEnterpriseEdition: pools.isEnterprise,
        adminLDAPEnabled : poolsDefault.ldapEnabled,
        ram: {
          total: poolsDefault.storageTotals.ram.total,
          quotaTotal: poolsDefault.storageTotals.ram.quotaTotal,
          quotaUsed: poolsDefault.storageTotals.ram.quotaUsed,
          indexMemoryQuota: mnMBtoBytesFilter(poolsDefault.indexMemoryQuota)
        },
        hdd: {
          total: poolsDefault.storageTotals.hdd.total,
          quotaTotal: poolsDefault.storageTotals.hdd.quotaTotal,
          used: poolsDefault.storageTotals.hdd.used,
          usedByData: poolsDefault.storageTotals.hdd.usedByData
        },
        buckets: { //Number of buckets
          total: bucketsList.length,
          membase: bucketsList.byType.membase.length,
          memcached: bucketsList.byType.memcached.length,
          ephemeral: bucketsList.byType.ephemeral.length
        },
        counters: poolsDefault.counters,
        nodes: {
          os: [],
          uptime: [],
          istats: [],
          services: {} //Services running and counts
        },
        istats: {
          avg_ops_last_week: [], // Average ops / sec last week
          avg_cmd_set_last_week: [], // Average sets / sec last week
          avg_query_requests_last_week: [], //Average N1QL queries / sec last week
          total_avg_view_accesses_last_week: [], //Average view reads / sec last week
          total_avg_index_num_rows_returned_last_week: [], //Average scans/sec last week
          total_ddocs: 0, //Number of total design docs
          total_views: 0, //Number of total views
          total_indexes: 0, //Number of total indexes
          total_curr_items_tot: 0, //Total number of items across all buckets
          total_fts_indexes: 0
        },
        browser: $window.navigator.userAgent
      };

      for(i in poolsDefault.nodes) {
        stats.nodes.os.push(poolsDefault.nodes[i].os);
        stats.nodes.uptime.push(poolsDefault.nodes[i].uptime);
        stats.nodes.istats.push(poolsDefault.nodes[i].interestingStats);
        var servicesContainerName = poolsDefault.nodes[i].services.sort().join(',');
        if (!stats.nodes.services[servicesContainerName]) {
          stats.nodes.services[servicesContainerName] = 0;
        }
        stats.nodes.services[servicesContainerName] ++;
      }

      var interestedBuckets = bucketsList.byType.membase.concat(bucketsList.byType.ephemeral);
      _.each(perBucketStats, function (perBucketStat, index) {
        var bucketName = interestedBuckets[index].name;
        var ddocs = perBucketStat[1].data;
        if (ddocs && ddocs.rows) {
          stats.istats.total_ddocs += ddocs.rows.length;
          _.each(ddocs.rows, function (row) {
            stats.istats.total_views += _.keys(row.doc.json.views || {}).length;
            stats.istats.total_views += _.keys(row.doc.json.spatial || {}).length;
          });
        }
        var statsInfo = perBucketStat[0].data;
        if (statsInfo) {
          var bucketStats = statsInfo.stats[bucketName];
          var indexStats = statsInfo.stats["@index-" + bucketName];
          var queriesStats = statsInfo.stats["@query"];
          var ftsStats = statsInfo.stats["@fts-" + bucketName];

          if (ftsStats) {
            stats.istats.total_fts_indexes += _.keys(_.reduce(ftsStats, function (result, value, key) {
              key = key.split("/");
              if (key.length === 3) {
                result[key[1]] = true;
              }
              return result;
            }, {})).length;
          }
          var avgNumRowsReturnedPerIndex = getAvgPerItem(indexStats, function (key) {
            key = key.split("/");
            return key.length === 3 && key[2] === "num_rows_returned" && key[0] === "index";
          });
          var avgViewAccessesPerView = getAvgPerItem(bucketStats, function (key) {
            key = key.split("/");
            return key.length === 3 && key[2] === "accesses" && key[0] === "views";
          });

          setPerBucketStat(stats, "avg_ops", bucketStats.ops);
          setPerBucketStat(stats, "avg_cmd_set", bucketStats.cmd_set);
          setPerBucketStat(stats, "total_avg_view_accesses", bucketStats && avgViewAccessesPerView);
          setPerBucketStat(stats, "total_avg_index_num_rows_returned", indexStats && avgNumRowsReturnedPerIndex);

          stats.istats.avg_query_requests_last_week = (queriesStats && queriesStats.query_requests) || []; //is not per bucket

          stats.istats.total_curr_items_tot += bucketStats.curr_items_tot ? bucketStats.curr_items_tot[bucketStats.curr_items_tot.length - 1] : 0;
        }
      });
      if (autoCompactionSettings) {
        stats.cluster_settings.compaction = {
          database_trigger_percent_enabled: !!autoCompactionSettings.databaseFragmentationThreshold.percentageFlag,
          database_trigger_percent_level: autoCompactionSettings.databaseFragmentationThreshold.percentage,
          database_trigger_size_enabled: !!autoCompactionSettings.databaseFragmentationThreshold.sizeFlag,
          database_trigger_size_MB: autoCompactionSettings.databaseFragmentationThreshold.size,
          view_trigger_percent_enabled: !!autoCompactionSettings.viewFragmentationThreshold.percentageFlag,
          view_trigger_percent_level: autoCompactionSettings.viewFragmentationThreshold.percentage,
          view_trigger_size_enabled: !!autoCompactionSettings.viewFragmentationThreshold.sizeFlag,
          view_trigger_size_MB: autoCompactionSettings.viewFragmentationThreshold.size,
          compaction_trigger_time_based_enabled: !!autoCompactionSettings.allowedTimePeriodFlag,
          compaction_trigger_time_based_start_time: {
            hour: autoCompactionSettings.allowedTimePeriod.fromHour,
            minute: autoCompactionSettings.allowedTimePeriod.fromMinute
          },
          index_trigger_percent_enabled: !autoCompactionSettings.indexCircularCompactionFlag,
          index_trigger_percent_level: autoCompactionSettings.indexFragmentationThreshold.percentage,
          index_trigger_circular_reuse_enabled: autoCompactionSettings.indexCircularCompactionFlag,
          index_trigger_circular_reuse_days: autoCompactionSettings.indexCircularCompactionDaysOfWeek,
          index_trigger_circular_reuse_start_time: {
            hour: autoCompactionSettings.indexCircularCompaction.fromHour,
            minute: autoCompactionSettings.indexCircularCompaction.fromMinute
          }
        };
      }
      if (autoFailoverSettings) {
        stats.cluster_settings.enable_auto_failover = autoFailoverSettings.data.enabled;
        stats.cluster_settings.failover_timeout = autoFailoverSettings.data.timeout;
      }
      if (indexSettings) {
        stats.cluster_settings.index_storage_mode = indexSettings.storageMode;
      }
      if (indexStatus) {
        stats.istats.total_indexes = indexStatus.indexes.length;
      }
      if (auditSettings) {
        stats.adminAuditEnabled = auditSettings.auditdEnabled;
      }
      calculateAvgWeekAndHour(stats, "avg_ops", true);
      calculateAvgWeekAndHour(stats, "avg_cmd_set", true);
      calculateAvgWeekAndHour(stats, "avg_query_requests", true);
      calculateAvgWeekAndHour(stats, "total_avg_view_accesses");
      calculateAvgWeekAndHour(stats, "total_avg_index_num_rows_returned");

      return stats;
    }

    mnSettingsNotificationsService.buildPhoneHomeThingy = function (mnHttpParams) {
      return $q.all([
        mnBucketsService.getBucketsByType(false, mnHttpParams),
        mnPools.get(mnHttpParams),
        mnPoolDefault.get(undefined, mnHttpParams)
      ]).then(function (resp) {
        var buckets = resp[0];
        var pools = resp[1];
        var poolDefault = resp[2];
        var perBucketQueries = [];

        angular.forEach(buckets.byType.membase.concat(buckets.byType.ephemeral), function (bucket) {
          var statsParams = {
            $stateParams: {
              zoom: "week",
              bucket: bucket.name
            }
          };
          var queries = [
            mnAnalyticsService.doGetStats(statsParams, mnHttpParams)
          ];
          if (_.indexOf(poolDefault.thisNode.services, "kv") > -1 && mnPermissions.export.cluster.bucket[bucket.name].views.read) {
            queries.push(mnViewsListService.getDdocs(bucket.name, mnHttpParams));
          } else {
            queries.push($q.when({}));
          }
          perBucketQueries.push($q.all(queries));
        });

        var queries = [
          $q.when(buckets),
          $q.all(perBucketQueries),
          $q.when(pools),
          $q.when(poolDefault)
        ];

        if (mnPoolDefault.export.compat.atLeast40 && mnPermissions.export.cluster.indexes.read) {
          queries[4] = mnGsiService.getIndexesState(mnHttpParams);
        }
        if (mnPools.export.isEnterprise && mnPermissions.export.cluster.admin.security.read && mnPoolDefault.export.compat.atLeast40) {
          queries[5] = mnAuditService.getAuditSettings();
        }
        if (mnPoolDefault.export.compat.atLeast40 && mnPermissions.export.cluster.indexes.read) {
          queries[6] = mnSettingsClusterService.getIndexSettings();
        }
        if (mnPermissions.export.cluster.settings.read) {
          queries[7] = mnSettingsAutoFailoverService.getAutoFailoverSettings();
        }
        if (mnPermissions.export.cluster.settings.read) {
          queries[8] = mnSettingsAutoCompactionService.getAutoCompaction();
        }

        return $q.all(queries).then(buildPhoneHomeThingy);
      });
    };

    mnSettingsNotificationsService.getUpdates = function (data, mnHttpParams) {
      return $http({
        method: 'JSONP',
        mnHttp: mnHttpParams,
        url: 'http://ph.couchbase.net/v2',
        timeout: 8000,
        params: {launchID: data.launchID, version: data.version}
      });
    };

    mnSettingsNotificationsService.maybeCheckUpdates = function (mnHttpParams) {
      return mnSettingsNotificationsService.getSendStatsFlag(mnHttpParams).then(function (sendStatsData) {
        sendStatsData.enabled = sendStatsData.sendStats;
        if (!sendStatsData.sendStats) {
          return sendStatsData;
        } else {
          return mnPools.get(mnHttpParams).then(function (pools) {
            return mnSettingsNotificationsService.getUpdates({
              launchID: pools.launchID,
              version: pools.implementationVersion
            }, mnHttpParams).then(function (resp) {
              return _.extend(_.clone(resp.data), sendStatsData);
            }, function (resp) {
              return sendStatsData;
            });
          });
        }
      })
    };

    mnSettingsNotificationsService.saveSendStatsFlag = function (flag) {
      return $http.post("/settings/stats", {sendStats: flag});
    };
    mnSettingsNotificationsService.getSendStatsFlag = function (mnHttpParams) {
      return $http({
        method: "GET",
        url: "/settings/stats",
        mnHttp: mnHttpParams
      }).then(function (resp) {
        return resp.data;
      });
    };


    return mnSettingsNotificationsService;
});
