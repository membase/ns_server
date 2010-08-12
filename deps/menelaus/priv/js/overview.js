var OverviewSection = {
  initLater: function () {
    BucketsSection.cells.detailedBuckets.subscribeValue(function (buckets) {
      $('#overview .buckets-number').text(buckets ? ViewHelpers.count(buckets.length, 'bucket') : '??');
    });

    DAO.cells.serversCell.subscribeValue(function (servers) {
      $('.active-servers-count').text(servers ? servers.active.length : '??');

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

    var spinner;
    BucketsSection.cells.detailedBuckets.subscribeValue(function (buckets) {
      var poolDetails = DAO.cells.currentPoolDetailsCell.value;
      if (!poolDetails || !buckets) {
        if (!spinner)
          spinner = overlayWithSpinner('#overview_clusters_block');
        return;
      }
      if (spinner) {
        spinner.remove();
        spinner = null;
      }

      var item = $('#overview_clusters_block .ram-item');

      var usedQuota = _.reduce(buckets, 0, function (acc, info) {
        return acc + info.basicStats.memUsed;
      });
      var bucketsQuota = _.reduce(buckets, 0, function (acc, info) {
        return acc + info.quota.ram;
      });
      var quotaTotal = poolDetails.storageTotals.ram.quotaTotal;
      item.find('.cluster-total').text(ViewHelpers.formatQuantity(quotaTotal, null, null, ' '));
      item.find('.used-quota').text(ViewHelpers.formatQuantity(usedQuota, null, null, ' '));
      item.find('.buckets-quota').text(ViewHelpers.formatQuantity(bucketsQuota, null, null, ' '));
      item.find('.unused-quota').text(ViewHelpers.formatQuantity(bucketsQuota - usedQuota, null, null, ' '));
      item.find('.quota-free').text(ViewHelpers.formatQuantity(quotaTotal - bucketsQuota, null, null, ' '));

      item.find('.used').css('width', calculatePercent(usedQuota, quotaTotal) + '%');
      item.find('.free').css('width', calculatePercent(bucketsQuota - usedQuota, quotaTotal) + '%');
    });
  },
  init: function () {
    _.defer($m(this, 'initLater'));

    // this fake cell makes sure our stats cell is not recomputed when pool details change
    this.statsCellArg = new Cell(function (poolDetails) {
      return 1;
    }, {
      poolDetails: DAO.cells.currentPoolDetailsCell
    });

    this.statsCell = new Cell(function (arg) {
      return future.get({url: '/pools/default/overviewStats'});
    }, {
      arg: this.statsCellArg
    });
    this.statsCell.subscribeValue($m(this, 'onStatsValue'));
  },
  plotGraph: function (graphJQ, stats, attr) {
    var data = stats[attr];

    var minX, minY = 1/0;
    var maxX, maxY = -1/0;
    var minInf = minY;
    var maxInf = maxY;

    var plotData = _.map(data, function (e, i) {
      var x = stats.timestamp[i];
      if (e <= minY) {
        minX = x;
        minY = e;
      }
      if (e >= maxY) {
        maxX = x;
        maxY = e;
      }
      return [x, e];
    });

    plotData = _.filter(plotData, function (e, i) {
      return (i % 5) == 0;
    });

    var chosenTicks = [];
    var prevTick = 0;
    var prevMins = -1;

    var tstamps = stats.timestamp;
    for (var i = 0; i < tstamps.length; i++) {
      var val = tstamps[i];
      if (prevTick + (14 * 60 * 1000) > val)
        continue;

      var date = new Date(tstamps[i]);
      var minutes = date.getMinutes();

      var minMod = minutes % 15;

      if (prevMins > minMod) {
        // force tick if we for some reason passed 15 minutes mark
        prevMins = minMod;
      } else {
        prevMins = minMod;
        // not 15 minutes mark, skip
        if (minMod != 0)
          continue;
      }

      prevTick = val;
      chosenTicks.push(val);
    }

    minY = 0;

    if (minY == maxY)
      maxY = 1;

    var graphMax = maxY + (maxY - minY) * 0.1;

    // this is ripped out of jquery.flot which is MIT licensed
    // Tweaks are mine. Bugs too.
    var yTicks = (function () {
      var delta = (maxY - minY) / 5;

      if (delta == 0.0)
        return [0, 1];

      var size, magn, norm;

      function floorInBase(n, base) {
        return base * Math.floor(n / base);
      }

      // pretty rounding of base-10 numbers
      var dec = -Math.floor(Math.log(delta) / Math.LN10);

      magn = Math.pow(10, -dec);
      norm = delta / magn; // norm is between 1.0 and 10.0

      if (norm < 1.5)
        size = 1;
      else if (norm < 3) {
        size = 2;
        // special case for 2.5, requires an extra decimal
        if (norm > 2.25) {
          size = 2.5;
          ++dec;
        }
      }
      else if (norm < 7.5)
        size = 5;
      else
        size = 10;

      size *= magn;

      function tickFormatter(v) {
        return ViewHelpers.formatQuantity(v, '', 1000);
      }

      var ticks = [];

      // spew out all possible ticks
      var start = floorInBase(minY, size),
      i = 0, v = Number.NaN, prev;
      do {
        prev = v;
        v = start + i * size;
        ticks.push(v);
        ++i;
      } while (v < maxY && v != prev);

      return ticks;
    })();

    $.plot(graphJQ,
           [{color: '#1d88ad',
             data: plotData}],
           {xaxis: {
             ticks: chosenTicks,
             tickFormatter: function (val, axis) {
               var date = new Date(val);
               var hours = date.getHours();
               var mins = date.getMinutes();
               var am = (hours > 1 && hours < 13);
               if (!am) {
                 if (hours == 0)
                   hours = 12;
                 else
                   hours -= 12;
               }
               if (hours == 12)
                 am = !am;
               var formattedHours = String(hours + 100).slice(1);
               var formattedMins = String(mins + 100).slice(1);
               return formattedHours + ":" + formattedMins + (am ? 'am' : 'pm');
             }
           },
            yaxis: {
              tickFormatter: function (val, axis) {
                return ViewHelpers.formatQuantity(val, '', 1000);
              },
              min: minY,
              max: graphMax,
              ticks: yTicks
            },
            grid: {
              borderWidth: 0,
              markings: function (opts) {
                // { xmin: , xmax: , ymin: , ymax: , xaxis: , yaxis: , x2axis: , y2axis:  };
                return [
                  {xaxis: {from: opts.xmin, to: opts.xmax},
                   yaxis: {from: opts.ymin, to: opts.ymin},
                   color: 'black'},
                  {xaxis: {from: opts.xmin, to: opts.xmin},
                   yaxis: {from: opts.ymin, to: opts.ymax},
                   color: 'black'}
                ]
              }
            }});

    function singleMarker(center, value) {
      var text;
      value = ViewHelpers.formatQuantity(value, '', 1000);

      text = String(value);
      var marker = $('<span class="marker"><span class="l"></span><span class="r"></span></span>');
      marker.find('.l').text(text);
      graphJQ.append(marker);
      marker.css({
        position: 'absolute',
        top: center.top - 16 + 'px',
        left: center.left - 10 + 'px'
      });
      return marker;
    }

    function drawMarkers(plot) {
      graphJQ.find('.marker').remove();

      if (minY != minInf && minY != 0) {
        var offset = plot.pointOffset({x: minX, y: minY});
        singleMarker(offset, minY).addClass('marker-min');
      }

      if (maxY != maxInf) {
        var offset = plot.pointOffset({x: maxX, y: maxY});
        singleMarker(offset, maxY).addClass('marker-max');
      }
    }

  },
  onStatsValue: function (stats) {
    if (!stats)
      return;
    this.plotGraph($('#overview_ops_graph'), stats, 'ops');
    this.plotGraph($('#overview_reads_graph'), stats, 'ep_io_num_read');
    this.statsCell.recalculateAfterDelay(30000);
  },
  onEnter: function () {
  }
};
