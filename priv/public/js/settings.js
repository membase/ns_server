/**
   Copyright 2011 Couchbase, Inc.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
 **/
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
