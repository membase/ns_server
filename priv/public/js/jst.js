var jst = (function () {

  return {
    analyticsRightArrow: function (aInner, params) {
      var a = $('<a>' + aInner + '</a>')[0];
      a.setAttribute('href', '#' + $.param(params));
      var li = document.createElement('LI');
      li.appendChild(a);

      return li;
    }
  };
})();