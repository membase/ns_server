(function() {

  var progressWrapper = $('#global_progress');
  var progressContainer = $('#global_progress_container');

  var tasks = [];
  var render = {};


  function refreshProgress() {
    if ($.isEmptyObject(tasks)) {
      progressWrapper.hide();
    } else {
      var html = "", keys = 0;
      _.each(tasks, function(obj) {
        html += render[obj.type](obj);
      });

      progressWrapper.toggleClass('disable_toggle', tasks.length < 2);
      progressContainer.html(html);
      progressWrapper.show();
    }
  }

  render.index = function(obj) {
    return '<li class="clearfix"><div class="usage_smallest">' +
      '<div class="used" style="width:' + obj.progress +
      '%"></div></div><span class="message">Indexing ' + obj.ddoc + '</span></li>';
  };


  render.rebalance = function(obj) {

    var servers = 0, progress = 0;

    _.each(obj.value, function(tmp, key) {
      if (typeof tmp.progress !== 'undefined') {
        servers++;
        progress += tmp.progress;
      }
    });

    return '<li class="clearfix"><div class="usage_smallest">' +
      '<div class="used" style="width:' + Math.round((progress / servers) * 100) +
      '%"></div></div><span class="message">Rebalancing ' + servers +
      ' nodes</span></li>';
  };


  progressWrapper.find('.toggle').bind('click', function() {
    if (!progressWrapper.is('.disable_toggle')) {
      progressWrapper.toggleClass('closed');
    }
  });

  DAL.onReady(function() {

    ViewsSection.tasksProgressCell.subscribe(function(active_tasks) {
      tasks = _.filter(tasks, function(val) { return val.type !== 'index'; });
      if (active_tasks.value.length > 0) {
        _.each(sumIndexProgress(active_tasks.value), function(val, key) {
          tasks.push({type: 'index', ddoc: key, progress: val});
        });
      }
      refreshProgress();
    });

    ServersSection.rebalanceProgress.subscribe(function() {
      tasks = _.filter(tasks, function(val) { return val.type !== 'rebalance'; });
      if (ServersSection.rebalanceProgress.value.status !== 'none') {
        tasks.push({type: 'rebalance', value: ServersSection.rebalanceProgress.value});
      }
      refreshProgress();
    });
  });

})();