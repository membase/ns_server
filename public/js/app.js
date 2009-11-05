$(function () {
  window.nav = {};

  nav.go = function (sec) {
    $.bbq.pushState({sec: sec});
  }

  $(window).bind('hashchange', function () {
    var sec = $.bbq.getState('sec') || 'overview';
    $('#middle_pane > div').css('display', 'none');
    $('#'+sec).css('display','block');
    setTimeout(function () {
      $(window).trigger('sec:' + sec);
    }, 10);
  });

  $(window).trigger('hashchange');

  $(window).bind('sec:overview', function () {
    var arr = [10, 5, 46, 100, 74, 25];
    for (var i = 0; i < 2; i++)
      arr = arr.concat(arr);
    $('#testgraph').sparkline(arr, {height: 60, width: 300});
  });
});
