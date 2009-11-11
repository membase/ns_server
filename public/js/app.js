/**
*
*  Base64 encode / decode
*  http://www.webtoolkit.info/
*
**/
// ALK Note: we might want to rewrite this.
// webtoolkit.info license doesn't permit removal of comments which js minifiers do.
// also utf8 handling functions are not really utf8, but CESU-8.
// I.e. it doesn't handle utf16 surrogate pairs at all
var Base64 = {
 
	// private property
	_keyStr : "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=",
 
	// public method for encoding
	encode : function (input) {
		var output = "";
		var chr1, chr2, chr3, enc1, enc2, enc3, enc4;
		var i = 0;
 
		input = Base64._utf8_encode(input);
 
		while (i < input.length) {
 
			chr1 = input.charCodeAt(i++);
			chr2 = input.charCodeAt(i++);
			chr3 = input.charCodeAt(i++);
 
			enc1 = chr1 >> 2;
			enc2 = ((chr1 & 3) << 4) | (chr2 >> 4);
			enc3 = ((chr2 & 15) << 2) | (chr3 >> 6);
			enc4 = chr3 & 63;
 
			if (isNaN(chr2)) {
				enc3 = enc4 = 64;
			} else if (isNaN(chr3)) {
				enc4 = 64;
			}
 
			output = output +
			this._keyStr.charAt(enc1) + this._keyStr.charAt(enc2) +
			this._keyStr.charAt(enc3) + this._keyStr.charAt(enc4);
 
		}
 
		return output;
	},
 
	// public method for decoding
	decode : function (input) {
		var output = "";
		var chr1, chr2, chr3;
		var enc1, enc2, enc3, enc4;
		var i = 0;
 
		input = input.replace(/[^A-Za-z0-9\+\/\=]/g, "");
 
		while (i < input.length) {
 
			enc1 = this._keyStr.indexOf(input.charAt(i++));
			enc2 = this._keyStr.indexOf(input.charAt(i++));
			enc3 = this._keyStr.indexOf(input.charAt(i++));
			enc4 = this._keyStr.indexOf(input.charAt(i++));
 
			chr1 = (enc1 << 2) | (enc2 >> 4);
			chr2 = ((enc2 & 15) << 4) | (enc3 >> 2);
			chr3 = ((enc3 & 3) << 6) | enc4;
 
			output = output + String.fromCharCode(chr1);
 
			if (enc3 != 64) {
				output = output + String.fromCharCode(chr2);
			}
			if (enc4 != 64) {
				output = output + String.fromCharCode(chr3);
			}
 
		}
 
		output = Base64._utf8_decode(output);
 
		return output;
 
	},
 
	// private method for UTF-8 encoding
	_utf8_encode : function (string) {
//		string = string.replace(/\r\n/g,"\n");
		var utftext = "";
 
		for (var n = 0; n < string.length; n++) {
 
			var c = string.charCodeAt(n);
 
			if (c < 128) {
				utftext += String.fromCharCode(c);
			}
			else if((c > 127) && (c < 2048)) {
				utftext += String.fromCharCode((c >> 6) | 192);
				utftext += String.fromCharCode((c & 63) | 128);
			}
			else {
				utftext += String.fromCharCode((c >> 12) | 224);
				utftext += String.fromCharCode(((c >> 6) & 63) | 128);
				utftext += String.fromCharCode((c & 63) | 128);
			}
 
		}
 
		return utftext;
	},
 
	// private method for UTF-8 decoding
	_utf8_decode : function (utftext) {
		var string = "";
		var i = 0;
		var c = c1 = c2 = 0;
 
		while ( i < utftext.length ) {
 
			c = utftext.charCodeAt(i);
 
			if (c < 128) {
				string += String.fromCharCode(c);
				i++;
			}
			else if((c > 191) && (c < 224)) {
				c2 = utftext.charCodeAt(i+1);
				string += String.fromCharCode(((c & 31) << 6) | (c2 & 63));
				i += 2;
			}
			else {
				c2 = utftext.charCodeAt(i+1);
				c3 = utftext.charCodeAt(i+2);
				string += String.fromCharCode(((c & 15) << 12) | ((c2 & 63) << 6) | (c3 & 63));
				i += 3;
			}
 
		}
 
		return string;
	}
 
}

function formatUptime(seconds, precision) {
  precision = precision || 8;

  var arr = [[86400, "days", "day"],
             [3600, "hours", "hour"],
             [60, "minutes", "minute"],
             [1, "seconds", "second"]];

  var rv = [];

  $.each(arr, function () {
    var period = this[0];
    var value = (seconds / period) >> 0;
    seconds -= value * period;
    if (value)
      rv.push(String(value) + ' ' + (value > 1 ? this[1] : this[2]));
    return !!--precision;
  });

  return rv.join(', ');
}

// Based on: http://ejohn.org/blog/javascript-micro-templating/
// Simple JavaScript Templating
// John Resig - http://ejohn.org/ - MIT Licensed
;(function(){
  var cache = {};

  this.tmpl = function tmpl(str, data){
    // Figure out if we're getting a template, or if we need to
    // load the template - and be sure to cache the result.

    var fn = !/\W/.test(str) && (cache[str] = cache[str] ||
                                 tmpl(document.getElementById(str).innerHTML));

    if (!fn) {
      var body = "var p=[],print=function(){p.push.apply(p,arguments);}," +
        "h=function(){return String(arguments[0]).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')};" +

      // Introduce the data as local variables using with(){}
      "with(obj){p.push('" +

      // Convert the template into pure JavaScript
      str
      .replace(/[\r\t\n]/g, " ")
      .split("{%").join("\t")
      .replace(/((^|%})[^\t]*)'/g, "$1\r") //'
      .replace(/\t=(.*?)%}/g, "',$1,'")
      .split("\t").join("');")
      .split("%}").join("p.push('")
      .split("\r").join("\\'")
        + "');}return p.join('');"

      // Generate a reusable function that will serve as a template
      // generator (and which will be cached).
      fn = new Function("obj", body);
    }

    // Provide some basic currying to the user
    return data ? fn( data ) : fn;
  };
})();

var StatGraphs = {
  update: function (stats) {
    var main = $('#overview_main_graph span')
    var ops = $('#overview_graph_ops')
    var gets = $('#overview_graph_gets')
    var sets = $('#overview_graph_sets')
    var misses = $('#overview_graph_misses')

    main.sparkline(stats.ops, {width: $(main.get(0).parentNode).innerWidth(), height: 200})
    ops.sparkline(stats.ops, {width: ops.innerWidth(), height: 100})
    gets.sparkline(stats.gets, {width: gets.innerWidth(), height: 100})
    sets.sparkline(stats.sets, {width: sets.innerWidth(), height: 100})
    misses.sparkline(stats.misses, {width: misses.innerWidth(), height: 100})
  }
}

function addBasicAuth(xhr, login, password) {
  var auth = 'Basic ' + Base64.encode(login + ':' + password);
  xhr.setRequestHeader('Authorization', auth);
}

$.ajaxSetup({
  error: function () {
    alert("FIXME: network or server-side error happened! We'll handle it better in the future.");
  },
  beforeSend: function (xhr) {
    if (Page.login) {
      addBasicAuth(xhr, Page.login, Page.password);
    }
  }
});

// port of bind() from prototype.js
Function.prototype.bind = function () {
  var self = this;
  var args = $.makeArray(arguments);
  var forThis = args.shift();
  return function () {
    return self.apply(forThis, args.concat($.makeArray(arguments)));
  }
};


function deferringUntilReady(body) {
  return function () {
    if (Page.ready) {
      body.apply(this, arguments);
      return;
    }
    var self = this;
    var args = arguments;
    Page.onReady(function () {
      body.apply(self, args);
    });
  }
}

var Page = {
  ready: false,
  onReady: function (thunk) {
    if (Page.ready)
      thunk.call(null);
    else
      $(window).one('dao:ready', function () {thunk();});
  },
  getStatsAsync: deferringUntilReady(function (callback) {
    // TODO: use current bucket
    $.get('/buckets/default/stats', null, callback, 'json');
  }),
  performLogin: function (login, password) {
    this.login = login;
    this.password = password;
    $.post('/ping', {}, function () {
      Page.ready = true;
      $(window).trigger('dao:ready');
    });
  },
  enterOverview: function () {
    Page.getStatsAsync(function (stats) {
      StatGraphs.update(stats.stats);
      var rows = $.map(stats.stats.hot_keys, function (e) {
        return $.extend({}, e, {total: 0 + e.gets + e.misses});
      });
      $('#top_key_table_container').get(0).innerHTML = tmpl('top_keys_template', {rows:rows});

      $('#server_list_container').get(0).innerHTML = tmpl('server_list_template', {rows: stats.servers});
    });
  },
  hookEvents: function () {
    $(window).bind('sec:overview', Page.enterOverview.bind(Page));
  }
};

function loginFormSubmit() {
  var login = $('#login_form [name=login]').val();
  var password = $('#login_form [name=password]').val();
  Page.performLogin(login, password);
  $(window).one('dao:ready', function () {
    $('#login_dialog').jqmHide();
  });
  return false;
}

window.nav = {
  go: function (sec) {
    $.bbq.pushState({sec: sec});
  }
};

$(function () {
  $('#login_dialog').jqm({modal: true}).jqmShow();
  setTimeout(function () {
    $('#login_dialog [name=login]').get(0).focus();
  }, 100);

  Page.hookEvents();

  Page.onReady(function () {
    $(window).bind('hashchange', function () {
      var sec = $.bbq.getState('sec') || 'overview';
      $('#middle_pane > div').css('display', 'none');
      $('#'+sec).css('display','block');
      setTimeout(function () {
        $(window).trigger('sec:' + sec);
      }, 10);
    });

    $(window).trigger('hashchange');
  });

  $('#server_list_container .expander').live('click', function (e) {
    var container = $('#server_list_container');

    var mydetails = $(e.target).parents("#server_list_container .primary").next();
    var opened = mydetails.hasClass('opened');

    container.find(".details").removeClass('opened');
    mydetails.toggleClass('opened', !opened);
  });
});
