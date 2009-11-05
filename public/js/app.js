$(function () {
  window.nav = {};

  nav.go = function (sec) {
    $.bbq.pushState({sec: sec});
  }

  $(window).bind('hashchange', function () {
    var sec = $.bbq.getState('sec') || 'overview';
    $('#middle_pane > div').css('display', 'none');
    $('#'+sec).css('display','block');
  });

  $(function () {
    $(window).trigger('hashchange');
  });
});
