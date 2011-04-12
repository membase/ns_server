var UpdatesNotificationsSection = {
  init: function () {
    var self = this;

    // All the infos that are needed to send out the statistics
    var statsInfo = Cell.compute(function (v) {
      return {
        pool: v.need(DAL.cells.currentPoolDetailsCell),
        buckets: v.need(DAL.cells.bucketsListCell)
      };
    });

    var phEnabled = Cell.compute(function(v) {
      // only make the GET request when we are logged in
      v.need(DAL.cells.mode);
      return future.get({url: "/settings/stats"});
    });

    phEnabled.subscribeValue(function(val) {
      if (val!==undefined) {
        // newVersion has 3 states, either:
        //  - string => new version available
        //  - false => no new version available
        //  - undefined => some error occured, no information available
        var newVersion = undefined;
        console.log("sendState setting was changed!", val);
        // Sending off stats is enabled...
        if (val.sendStats) {
          var errorFun = function(arg1, arg2, arg3) {
            self.renderTemplate(val.sendStats, undefined);
          };

          statsInfo.getValue(function(s) {
            console.log('server:', s);
            var numMembase = 0;
            for (var i in s.buckets) {
              if (s.buckets[i].bucketType == "membase")
                numMembase++;
            }
            var nodeStats = {
              os: [],
              uptime: []
            };
            for(i in s.pool.nodes) {
              nodeStats.os.push(s.pool.nodes[i].os);
              nodeStats.uptime.push(s.pool.nodes[i].uptime);
            }
            var stats = {
              version: DAL.version,
              componentsVersion: DAL.componentsVersion,
              numNodes: s.pool.nodes.length,
              ram: {
                total: s.pool.storageTotals.ram.total,
                quotaTotal: s.pool.storageTotals.ram.quotaTotal,
                quotaUsed: s.pool.storageTotals.ram.quotaUsed
              },
              buckets: {
                total: s.buckets.length,
                membase: numMembase,
                memcached: s.buckets.length - numMembase
              },
              nodes: nodeStats,
              browser: navigator.userAgent
            };
            // This is the request that actually sends the data
            $.ajax({
              url: self.remote.stats,
              dataType: 'jsonp',
              data: {stats: JSON.stringify(stats)},
              error: function() {
                  self.renderTemplate(true, undefined);
              },
              timeout: 2000,
              success: function (data) {
                self.renderTemplate(true, data);
              }
            });
          });

        } else {
          self.renderTemplate(false, undefined);
        }
      }
    });

    $('#notifications').delegate("a.more_info", "click", function(e) {
      e.preventDefault();
      $('#notifications p.more_info').slideToggle();
    });

    $('#notifications .save_button').click(function() {
      var sendStatus = $('#notification-updates').is(':checked');
      postWithValidationErrors('/settings/stats',
                               $.param({sendStats: sendStatus}),
                               function() {
          console.log('new status posted. recalculate cells');
          phEnabled.recalculate();
      });
    });
  },
  //   - sendStats:boolean Whether update notifications are enabled or not
  //   - data:object Consists of everything that comes back from the
  //     proxy that contains the information about software updates. The
  //     object consists of:
  //     - newVersion:undefined|false|string If it is a string a new version
  //       is available, it is false no now version is available. undefined
  //       means that an error occured while retreiving the information
  //     - links:object An object that contains links to the download and
  //       release notes (keys are "download" and "release").
  //     - info:string Some additional information about the new release
  //       (may contain HTML)
  renderTemplate: function(sendStats, data) {
    var newVersion;
    // data might be undefined.
    if (data) {
      newVersion = data.newVersion;
    }
    renderTemplate('leftNav_updates',
                   {enabled: sendStats, newVersion: newVersion},
                   $i('leftNav_updates_container'));
    renderTemplate('notifications_block',
                   $.extend(data, {enabled: sendStats, version: DAL.version}),
                   $i('notifications_block_container'));
  },
  remote: {
    stats: 'http://vmische.appspot.com/stats',
    email: 'http://vmische.appspot.com/email'
  },
  onEnter: function () {
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  },
  onLeave: function () {
  }
};
