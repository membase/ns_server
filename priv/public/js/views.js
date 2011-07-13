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

var sampleDocs = [{
   "_id": "234235124",
   "_rev": "3-12342341234",
   "type": "event",
   "title": "meeting",
   "where": "coffee bar",
   "hosts": [
       "benjamin@couchbase.com"
   ]
},
{
  "_id": "0594680c9ba809979a8e5f9a8000027c",
  "_rev": "3-7f43cdfce1b537739736a97c4eb78d62",
  "created_at": "2010-07-04T18:06:34.020Z",
  "profile": {
      "rand": "0.8309284392744303",
      "email": "jchris@couch.io",
      "url": "http://jchrisa.net",
      "gravatar_url": "http://www.gravatar.com/avatar/6f09a637f926f04d9b34bfe10e94bd3e.jpg?s=40&d=identicon",
      "name": "jchris"
  },
  "message": "refactor #focus evently.nav so it is properly bound to login and logout status",
  "state": "done",
  "publish": true,
  "type": "task",
  "edit_at": "2010-07-11T22:08:52.928Z",
  "edit_by": "jchris"
},
{
  "_id": "1643684c68d03fb70bc98d88a8896d0d",
  "_rev": "6-ff271e27fd0edfd88afb1d16e1363f79",
  "urls": {
      "@doppler": "http://twitter.com/doppler",
      "Web Developer, SXSW": "http://sxsw.com",
      "github.com/doppler": "http://github.com/doppler"
  },
  "bio": "I've been playing with and using CouchDB since version 0.9.0, sometime in early 2009. The first real app I created on CouchDB was to solve the problem of needing to provide an API to query SXSW schedule data, to be used by a 3rd-party developer creating an iPhone app. I'm hoping to build on that idea for SXSW 2011.",
  "hometown": "Austin, TX",
  "name": "David Rose",
  "_attachments": {
      "Photo on 2010-09-10 at 14.44.jpg": {
          "content_type": "image/jpeg",
          "revpos": 5,
          "digest": "md5-dlyF/44110seO+xxDgrkHA==",
          "length": 79027,
          "stub": true
      }
  }
}];

function isDevModeDocId(id) {
  return (id.substr(0,12) === '_design/dev_')
    ? true
    : false;
}

var ViewsSection = {
  init: function () {
    var self = this;

    var tabs = self.tabs = new TabsCell("viewsTab",
                             "#views .tabs",
                             "#views .panes > div",
                             ["production", "development"]);
    tabs.subscribeValue(function (tab) {
      $('#views')[tab == 'development' ? 'addClass' : 'removeClass']('in-development');
    });

    var bucketName;
    var dbUrl = self.dbUrl = Cell
      .needing(DAL.cells.capiBase, StatsModel.statsBucketURL)
      .compute(function (v, baseUri, uri) {
        bucketName = decodeURIComponent(uri).split('/').pop();
        return baseUri + bucketName;
      });

    var allDesignDocs = self.allDesignDocs = Cell
      .needing(dbUrl)
      .compute(function (v, dbUrl) {
        return future.get({url: dbUrl + '/_all_docs?startkey="_design/"&endkey="_design0"&include_docs=true'})
      });


    allDesignDocs.subscribe(function (cell) {
      function filter(doc) {
        return isDevModeDocId(doc.id);
      }

      renderTemplate('views_list', {
          rows: _.reject(cell.value.rows, filter),
          bucketName: bucketName
        }, $i('production_views_list_container'));
      renderTemplate('views_list', {
          rows: _.select(cell.value.rows, filter),
          bucketName: bucketName
        }, $i('development_views_list_container'));
    });

    // On "Delete" we notify the user that the views in this Design Doc
    // will no longer be accessible and upon the user clicking "Delete"
    // within the dialog, we DELETE the doc.
    $('#views .btn_delete:not(.disabled)').live('click', function (ev) {
      var ddocInfo = $(ev.target).closest('tbody');
      // TODO: celluralize this? or put this in a subscribe?
      var docUrl = dbUrl.value + '/' + encodeURIComponent(ddocInfo.data('name')) + '?rev=' + ddocInfo.data('rev');
      showDialog('delete_designdoc_confirmation_dialog', {
        closeOnEscape: false,
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();

          $.ajax({type:"DELETE", url: docUrl,
            success: function () {
              ddocInfo.remove();
              hideDialog('delete_designdoc_confirmation_dialog');
            },
            error: function (jqXHR, error, reason) {
              if (jqXHR.status === 405) {
                alert(reason + '...yet!');
              }
            }
          });
        }]]
      });
    });

    $('#views .btn_copy:not(.disabled)').live('click', function (ev) {
      var ddocInfo = $(ev.target).closest('tbody');
      var docId = ddocInfo.data('name');
      // TODO: celluralize this? or put this in a subscribe?
      var docUrl = dbUrl.value + '/' + docId + '?rev=' + ddocInfo.data('rev');
      // TODO: get dev_mode value from form (replace undefined)
      var dev_mode = undefined || true;
      var design_doc_name = ddocInfo.data('name');
      var dialog = $($i('copy_designdoc_dialog'));

      dialog.find('.designdoc_name').val(design_doc_name.split('/').pop().replace(/dev_/, ''));
      dialog.find('label').click(function (ev) {
        ev.preventDefault();
        var label = $(ev.target);
        label.find(':radio').prop('checked', true);
        label.find('.designdoc_name').prop('disabled', false).focus();
        label.siblings('label').find('.designdoc_name').prop('disabled', true);
      });

      showDialog(dialog, {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          var data = {};
          $.each(dialog.find('form').serializeArray(), function (i, field) {
            data[field.name] = field.value;
          });

          // TODO: get new design_doc_name from the form, throw error if undefined
         $.ajax({type:"COPY", url: docUrl,
           headers: {
             'Destination': data.prefix + '/' + data.name
           },
           success: function () {
             // TODO: switch to tab containing the copied document
             allDesignDocs.recalculate();
             hideDialog('copy_designdoc_dialog');
           }
         });

        }]]
      });
    });

    $('#views .btn_create:not(.disabled)').live('click', function (ev) {
      var dialog = $($i('copy_view_dialog'));
      dialog.find('input.designdoc_name, input.view_name').val('');
      // TODO: celluralize this? or put this in a subscribe?
      showDialog(dialog, {
        title: 'Create View',
        closeOnEscape: false,
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();

          var doc = {"_id": '_design/dev_' + dialog.find('input.designdoc_name').val(),
                     "language": "javascript",
                     "views": {}};
          doc.views[dialog.find('input.view_name').val()] = {
              "map": "function (doc) {\n  emit(doc._id, null);\n }"
            };
          $.ajax({type:"POST", url: dbUrl.value, data: JSON.stringify(doc),
            contentType: 'application/json',
            success: function () {
              self.allDesignDocs.recalculate();
              hideDialog(dialog);
            }
          });
        }]]
      });
    });
  },
  onEnter: function () {
  },
  navClick: function () {
  }
};

var ViewDevSection = {
  init: function() {
    var self = this;

    $('#built_in_reducers a').click(function(ev) {
      $('#viewcode_reduce').text($(ev.target).text());
    });

    $('#preview_random_doc').click(function(ev) {
      ev.stopPropagation();
      var jq = $('#sample_docs pre');
      var u = 2;
      var l = 0;
      var rand = Math.floor((Math.random() * (u-l+1))+l);
      jq.html($.futon.formatJSON(sampleDocs[rand], {html: true}));

      if (jq.closest('.darker_block').hasClass('closed')) {
        jq.closest('.darker_block').removeClass('closed');
      }
    }).trigger('click');

    // cells
    var bucketName = self.bucketName = new StringHashFragmentCell("bucketName");
    var docId = self.docId = new StringHashFragmentCell("docId");
    var viewName = self.viewName = new StringHashFragmentCell("viewName");
    var dbUrl = self.dbUrl = Cell
    .needing(DAL.cells.capiBase, bucketName)
    .compute(function (v, baseUri, bucketName) {
      return baseUri + bucketName;
    });

    var currentDoc = self.currentDoc = Cell
      .needing(dbUrl, docId)
      .compute(function (v, dbUrl, docId) {
        return future.get({url: dbUrl + '/' + docId});
      });

    var currentView = self.currentView = Cell
      .needing(currentDoc, viewName)
      .compute(function (v, ddoc, viewName) {
        return ddoc.views[viewName];
      });

    var viewResults = self.viewResults = Cell
      .needing(dbUrl, docId, viewName)
      .compute(function (v, dbUrl, docId, viewName) {
        return future.get({url: dbUrl + '/' + docId + '/_view/' + viewName + '?limit=10'});
      });

    // subscriptions
    currentView.subscribeValue(function (view) {
      if (view === undefined) {
        return;
      } else {
        $('#viewcode_map').text(view.map);
        $('#viewcode_reduce').text(view.reduce);
      }
    });

    docId.subscribeValue(function(name) {
      if (name === undefined) {
        return;
      } else {
        $('#view_development h1 .designdoc_name').html(name);
        $('#save_and_run_view')[isDevModeDocId(name) ? 'addClass' : 'removeClass']('disabled');
      }
    });

    viewName.subscribeValue(function(name) {
      $('#view_development h1 .view_name').html(name);
    });

    viewResults.subscribeValue(function(results) {
      if (results === undefined) {
        return;
      } else {
        renderTemplate('view_results', results);
      }
    });

    $('#save_and_run_view:not(.disabled)').live('click', function(ev) {
      self.saveViewChanges();
    });

    $('#save_view_as:not(.disabled)').live('click', function(ev) {
      var dialog = $($i('copy_view_dialog'));
      dialog.find('.designdoc_name').val(self.docId.value.split('/').pop());
      dialog.find('.view_name').val(self.viewName.value);
      showDialog(dialog, {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          var data = {};
          $.each(dialog.find('form').serializeArray(), function (i, field) {
            data[field.name] = field.value;
          });

          var viewCode = {
            map: $("#viewcode_map").val(),
            reduce: $("#viewcode_reduce").val() || undefined
          };

          function save(doc) {
            if (!doc) {
              doc = {
                  _id: '_design/' + data.designdoc_name,
                  language: 'javascript'
              };
            } else {
              doc = JSON.parse(doc);
            }
            // TODO: add view language error handling
            if (doc.views === undefined) doc.views = {};
            doc.views[data.view_name] = viewCode;
            console.log('views', doc.views);
            $.ajax({type:"PUT",
                    url: dbUrl.value + '/_design/' + data.designdoc_name,
              data: JSON.stringify(doc),
              contentType: 'application/json',
              success: function (resp) {
                // "converting" the location.hash into a valid query string for $.param.querystring() parsing
                var qs = '?' + location.hash.substr(1);
                var newqs = $.param.querystring(qs, 'docId=_design/' + data.designdoc_name + '&viewName=' + data.view_name);
                location.reload(true);
              }
            });
          }

          $.ajax({type:"GET", url: dbUrl.value + '/_design/' + data.designdoc_name,
            error: function(jqXHR, error, reason) {
              if (jqXHR.status === 404) {
                save(null);
              } else {
                alert(reason);
              }
            },
            success: function (doc) {
              save(doc);
            }
          });
        }]]
      });
    });
  },
  onEnter: function () {
  },
  navClick: function () {
  },
  saveViewChanges: function() {
    var self = this;
    var designDocId = encodeURIComponent(self.docId.value);
    var localViewName = decodeURIComponent(self.viewName.value);
    $.getJSON(self.dbUrl.value + '/' + designDocId, function(doc) {
        var viewDef = doc.views[localViewName];
        viewDef.map = $("#viewcode_map").val();
        viewDef.reduce = $("#viewcode_reduce").val() || undefined;
        $.ajax({type:"POST", data: JSON.stringify(doc),
          url: self.dbUrl.value,
          contentType: 'application/json',
          success: function(data) {
            self.viewResults.recalculate();
          }
        });
      }
    );
  },
  viewNotFound: function() {
    // TODO: use this in case viewName is not set
    genericDialog({buttons: {ok: true, cancel: false},
      header: "View Not Found",
      text: "The view you requested is not part of this design document. " +
      "We'll return to the Design Document list to let you reselect.",
      callback: function (e, btn, dialog) {
        var add = '';
        if (isDevModeDocId(docId.value)) {
          add = '&viewsTab=1';
        }
        ViewsSection.allDesignDocs.recalculate();
        location.hash = '#sec=views&statsBucket=/pools/default/buckets/' + bucketName.value + add;
      }
     });
  }
};
