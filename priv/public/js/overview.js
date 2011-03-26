var OverviewSection = {
  initLater: function () {
    DAL.cells.bucketsListCell.subscribeValue(function (buckets) {
      $('#overview .buckets-number').text(buckets ? ViewHelpers.count(buckets.length, 'bucket') : '??');
    });

    DAL.cells.serversCell.subscribeValue(function (servers) {
      var reallyActiveNodes = _.select(servers ? servers.active : [], function (n) {
        return n.clusterMembership == 'active';
      });
      $('.active-servers-count').text(servers ? reallyActiveNodes.length : '??');

      var block = $('#overview_servers_block');
      if (!servers) {
        block.find('.alert_num').hide();
        return;
      }
      var pending = servers.pending;
      var failedOver = _.select(servers.allNodes, function (node) {
        return node.clusterMembership == 'inactiveFailed';
      });
      var down = _.select(servers.allNodes, function (node) {
        return node.status != 'healthy';
      });

      function updateCount(selector, count) {
        var span = block.find(selector).text(count);
        span.parents('.alert_num')[count ? 'show' : 'hide']();
        span.parents('.alert_num').parents('li')[count ? 'removeClass' : 'addClass']('is-zero');
      }

      updateCount('.failed-over-count', failedOver.length);
      updateCount('.down-count', down.length);
      updateCount('.pending-count', pending.length);
    });

    DAL.cells.currentPoolDetailsCell.ensureMetaCell().subscribeValue(function (meta) {
      if (!meta || meta.stale === undefined)
        return;
      $('#overview .staleness-notice')[meta.stale ? 'show' : 'hide']();
    });

    DAL.cells.currentPoolDetailsCell.subscribeValue(function (poolDetails) {
      if (!poolDetails || !poolDetails.storageTotals
          || !poolDetails.storageTotals.ram || !poolDetails.storageTotals.hdd) {
        $('#overview_clusters_block').hide();
        return;
      }
      $('#overview_clusters_block').show();

      ;(function () {
        var item = $('#overview_clusters_block .ram-item');

        var ram = poolDetails.storageTotals.ram;
        var usedQuota = ram.usedByData;
        var bucketsQuota = ram.quotaUsed;
        var quotaTotal = ram.quotaTotal;
        var gaugeOptions = {
          topAttrs: {'class': 'line_cnt'},
          usageAttrs: {'class': 'usage_biggest'},
          topLeft: ['Total Allocated', ViewHelpers.formatMemSize(bucketsQuota)],
          topRight: ['Total in Cluster', ViewHelpers.formatMemSize(quotaTotal)],
          items: [
            {name: 'In Use',
             value: usedQuota,
             attrs: {style: 'background-position: 0 -31px;'},
             tdAttrs: {style: 'color:#1878a2;'}},
            {name: 'Unused',
             value: bucketsQuota - usedQuota,
             attrs: {style: 'background-position: 0 -62px;'},
             tdAttrs: {style: 'color:#409f05;'}},
            {name: 'Unallocated',
             value: quotaTotal - bucketsQuota,
             tdAttrs: {style: 'color:#444245;'}}
          ],
          markers: [{value: bucketsQuota,
                     attrs: {style: 'background-color:#e43a1b'}}]
        };
        if (gaugeOptions.items[1].value < 0) {
          gaugeOptions.items[0].value = bucketsQuota;
          gaugeOptions.items[1] = {
            name: 'Overused',
            value: usedQuota - bucketsQuota,
            attrs: {style: 'background-position: 0 -93px;'},
            tdAttrs: {style: 'color:#e43a1b;'}
          };
          if (usedQuota < quotaTotal) {
            _.extend(gaugeOptions.items[2], {
              name: 'Available',
              value: quotaTotal - usedQuota
            });
          } else {
            gaugeOptions.items.length = 2;
            gaugeOptions.markers << {value: quotaTotal,
                                     attrs: {style: 'color:#444245;'}}
          }
        }

        item.find('.line_cnt').replaceWith(memorySizesGaugeHTML(gaugeOptions));
      })();

      ;(function () {
        var item = $('#overview_clusters_block .disk-item');

        var hdd = poolDetails.storageTotals.hdd;

        var usedSpace = hdd.usedByData;
        var total = hdd.total;
        var other = hdd.used - usedSpace;
        var free = hdd.free;

        item.find('.line_cnt').replaceWith(memorySizesGaugeHTML({
          topAttrs: {'class': 'line_cnt'},
          usageAttrs: {'class': 'usage_biggest'},
          topLeft: ['Usable Free Space', ViewHelpers.formatMemSize(free)],
          topRight: ['Total Cluster Storage', ViewHelpers.formatMemSize(total)],
          items: [
            {name: 'In Use',
             value: usedSpace,
             attrs: {style: "background-position: 0 -31px;"},
             tdAttrs: {style: "color:#1878A2;"}},
            {name: 'Other Data',
             value: other,
             attrs: {style:"background-position: 0 -124px;"},
             tdAttrs: {style:"color:#C19710;"}},
            {name: "Free",
             value: total - other - usedSpace,
             tdAttrs: {style:"color:#444245;"}}
          ],
          markers: [
            {value: other + usedSpace + free,
             attrs: {style: "background-color:#E43A1B;"}}
          ]
        }));
      })();
    });
  },
  init: function () {
    _.defer($m(this, 'initLater'));

    // this fake cell makes sure our stats cell is not recomputed when pool details change
    this.statsCellArg = new Cell(function (poolDetails, mode) {
      if (mode != 'overview')
        return;
      return 1;
    }, {
      poolDetails: DAL.cells.currentPoolDetailsCell,
      mode: DAL.cells.mode
    });

    this.statsCell = Cell.mkCaching(function (arg) {
      return future.get({url: '/pools/default/overviewStats',
                         stdErrorMarker: true});
    }, {
      arg: this.statsCellArg
    });

    this.statsCell.subscribe(function (cell) {
      var ts = cell.value.timestamp;
      var interval = ts[ts.length-1] - ts[0];
      if (isNaN(interval) || interval < 15000)
        cell.recalculateAfterDelay(2000);
      else if (interval < 300000)
        cell.recalculateAfterDelay(10000);
      else
        cell.recalculateAfterDelay(30000);
    });

    this.statsToRenderCell = new Cell(function (stats, mode) {
      if (mode == 'overview')
        return stats;
    }, {
      mode: DAL.cells.mode,
      stats: this.statsCell
    })
    this.statsToRenderCell.subscribeValue($m(this, 'onStatsValue'));
  },
  plotGraph: function (graphJQ, stats, attr) {
    var now = (new Date()).valueOf();
    var tstamps = stats.timestamp || [];
    var breakInterval;
    if (tstamps.length > 1)
      breakInterval = (tstamps[tstamps.length-1] - tstamps[0])/30;
    plotStatGraph(graphJQ, stats[attr], tstamps, {
      lastSampleTime: now,
      breakInterval: breakInterval,
      processPlotOptions: function (plotOptions, plotDatas) {
        var firstData = plotDatas[0];
        var t0 = firstData[0][0];
        var t1 = now;
        if (t1 - t0 < 300000) {
          plotOptions.xaxis.ticks = [t0, t1];
          plotOptions.xaxis.tickSize = [null, "minute"];
        }
        return plotOptions;
      }
    });
  },
  onStatsValue: function (stats) {
    var haveStats = true;
    if (!stats || DAL.cells.mode.value != 'overview')
      haveStats = false;
    else if (stats.timestamp.length < 2)
      haveStats = false;

    var item = $('#overview_ops_graph').parent().parent();
    if (haveStats) {
      item.removeClass('no-samples-yet');
      this.plotGraph($('#overview_ops_graph'), stats, 'ops');
      this.plotGraph($('#overview_reads_graph'), stats, 'ep_io_num_read');
    } else {
      item.addClass('no-samples-yet');
    }
  },
  onEnter: function () {
  }
};
