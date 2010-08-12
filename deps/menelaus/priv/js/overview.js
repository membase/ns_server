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
  },
  onEnter: function () {
  }
};
