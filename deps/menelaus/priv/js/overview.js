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

    BucketsSection.cells.detailedBuckets.subscribeValue(function (buckets) {
      var poolDetails = DAO.cells.currentPoolDetailsCell.value;
      if (!poolDetails || !buckets) {
        $('#overview_clusters_block').hide();
        return;
      }
      $('#overview_clusters_block').show();

      ;(function () {
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
        item.find('.free').css('width', calculatePercent(bucketsQuota, quotaTotal) + '%');
      })();

      ;(function () {
        var item = $('#overview_clusters_block .disk-item');

        var usedQuota = _.reduce(buckets, 0, function (acc, info) {
          return acc + info.basicStats.diskUsed;
        });
        var bucketsQuota = _.reduce(buckets, 0, function (acc, info) {
          return acc + info.quota.hdd;
        });
        var total = poolDetails.storageTotals.hdd.total;
        var other = poolDetails.storageTotals.hdd.used - usedQuota;

        var committed = bucketsQuota + other;

        item.find('.cluster-total').text(ViewHelpers.formatQuantity(total, null, null, ' '));
        item.find('.used-quota').text(ViewHelpers.formatQuantity(usedQuota, null, null, ' '));
        item.find('.buckets-quota').text(ViewHelpers.formatQuantity(committed, null, null, ' '));
        item.find('.unused-quota').text(ViewHelpers.formatQuantity(bucketsQuota - usedQuota, null, null, ' '));
        item.find('.other-data').text(ViewHelpers.formatQuantity(other, null, null, ' '));
        item.find('.quota-free').text(ViewHelpers.formatQuantity(Math.abs(total - committed), null, null, ' '));

        var overcommitted = (committed > total);
        item[overcommitted ? 'addClass' : 'removeClass']('overcommitted');
        if (!overcommitted) {
          item.find('.other').css('width', calculatePercent(other, total) + '%');
          item.find('.used').css('width', calculatePercent(usedQuota + other, total) + '%');
          item.find('.free').css('width', calculatePercent(committed, total) + '%');
        } else {
          item.find('.unused-quota').text(ViewHelpers.formatQuantity(total - other, null, null, ' '));
          item.find('.other').css('width', calculatePercent(other, committed) + '%');
          item.find('.used').css('width', calculatePercent(usedQuota + other, committed) + '%');
          item.find('.free').css('width', calculatePercent(total, committed) + '%');
        }
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
      poolDetails: DAO.cells.currentPoolDetailsCell,
      mode: DAO.cells.mode
    });

    this.statsCell = new Cell(function (arg) {
      return future.get({url: '/pools/default/overviewStats', ignoreErrors: true});
    }, {
      arg: this.statsCellArg
    });
    this.statsCell.keepValueDuringAsync = true;

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
      mode: DAO.cells.mode,
      stats: this.statsCell
    })
    this.statsToRenderCell.subscribeValue($m(this, 'onStatsValue'));
  },
  plotGraph: function (graphJQ, stats, attr) {
    var data = stats[attr];
    var tstamps = stats.timestamp;

    // not enough data
    if (tstamps.length < 2)
      return;

    var minX, minY = 1/0;
    var maxX, maxY = -1/0;
    var minInf = minY;
    var maxInf = maxY;

    var decimation = 1;

    while (data.length / decimation >= 120) {
      decimation <<= 1;
    }

    if (decimation != 1) {
      tstamps = decimateNoFilter(decimation, tstamps);
      data = decimateSamples(decimation, data);
    }

    var plotData = _.map(data, function (e, i) {
      var x = tstamps[i];
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

    var chosenTicks = [];
    var prevTick = 0;
    var prevMins = -1;

    var fivemins = 5 * 60 * 1000;

    var mins14 = 14 * 60 * 1000;

     for (var i = 0; i < tstamps.length; i++) {
       var val = tstamps[i];
       if (prevTick + mins14 > val)
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

     if (chosenTicks.length < 2) {
       var leftBound = plotData[0][0];
       var rightBound = plotData[plotData.length-1][0];
       var otherPoint = chosenTicks[0];
       if (chosenTicks.length &&  leftBound + fivemins < otherPoint && otherPoint + fivemins < rightBound)
         chosenTicks = [leftBound, otherPoint, rightBound];
       else
         chosenTicks = [leftBound, rightBound];
     } else if (plotData[plotData.length-1][0] - fivemins > chosenTicks[chosenTicks.length-1]){
       chosenTicks.push(plotData[plotData.length-1][0]);
     }

     minY = 0;

     if (minY == maxY)
       maxY = 1;

     var graphMax = maxY + (maxY - minY) * 0.15;

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

     var preparedQ = ViewHelpers.prepareQuantity(yTicks[yTicks.length-1], 1000);

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
                 if (val == 0)
                   return '0';
                 return [truncateTo3Digits(val/preparedQ[0]), preparedQ[1]].join('');
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
     var haveStats = true;
     if (!stats || DAO.cells.mode.value != 'overview')
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
