var SettingsSection = {
  processSave: function(self, continuation) {
    var dialog = genericDialog({
      header: 'Saving...',
      text: 'Saving settings.  Please wait a bit.',
      buttons: {ok: false, cancel: false}});

    var form = $(self);

    var postData = serializeForm(form);

    form.find('.warn li').remove();

    postWithValidationErrors($(self).attr('action'), postData, function (data, status) {
      if (status != 'success') {
        var ul = form.find('.warn ul');
        _.each(data, function (error) {
          var li = $('<li></li>');
          li.text(error);
          ul.prepend(li);
        });
        $('html, body').animate({scrollTop: ul.offset().top-100}, 250);
        return dialog.close();
      }

      continuation = continuation || function () {
        reloadApp(function (reload) {
          if (data && data.newBaseUri) {
            var uri = data.newBaseUri;
            if (uri.charAt(uri.length-1) == '/')
              uri = uri.slice(0, -1);
            uri += document.location.pathname;
          }
          _.delay(_.bind(reload, null, uri), 1000);
        });
      }

      continuation(dialog);
    });
  }
};
