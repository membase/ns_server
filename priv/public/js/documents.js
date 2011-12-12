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

function alertDialog(alertMsg) {
  var dialog = genericDialog({
    buttons: {ok: true},
    header: "Alert",
    textHTML: alertMsg,
    callback: function (e, btn, dialog) {
      dialog.close();
    }
  });
}

var DocumentsModel = {};

(function (self) {
  self.bucketName = new StringHashFragmentCell("bucketName");

  self.documentsBucketCell = Cell.compute(function (v) {
    var section = v.need(DAL.cells.mode);
    if (section !== 'edit_doc' && section !== 'documents') {
      // force to undefined when in non-interesting section to prevent
      // dependant cells from being computed
      return;
    }

    var selected = v(DocumentsModel.bucketName);
    if (selected) {
      return selected;
    }
    var buckets = v.need(DAL.cells.bucketsListCell).byType.membase;
    var bucketInfo = _.detect(buckets, function (info) {
      return info.name === "default"
    }) || buckets[0];

    if (!bucketInfo) {
      return null;
    }
    return bucketInfo.name;
  });

  // bucket drop-down population and onChange events
  (function () {

    var cell = Cell.compute(function (v) {

      var mode = v.need(DAL.cells.mode);
      if (mode != 'edit_doc' && mode != 'documents') {
        return;
      }

      var buckets = v.need(DAL.cells.bucketsListCell).byType.membase;
      var selectedBucketName = v.need(DocumentsModel.documentsBucketCell);
      return {
        list: _.map(buckets, function (info) { return [info.name, info.name] }),
        selected: selectedBucketName
      };
    });

    $('#docs_buckets_select, #doc_buckets_select').each(function() {
      $(this).bindListCell(cell, {
        onChange: function (e, newValue) {
          DocumentsModel.bucketName.setValue(newValue);
        }
      });
    });

  })();
})(DocumentsModel);

var DocumentsSection = {

  init: function () {

    var self = this;

    // Prepare an empty document then send the user to edit
    function createDoc(bucket, id, callback) {

      // Do not do extra id validation here, leave that to the server
      if (id === '') {
        alertDialog('Document ID cannot be empty');
        return;
      }

      couchReq('PUT', buildDocURL(self.dbUrlCell.value, id), {_id: id}, function() {
        document.location.href = '#sec=edit_doc&bucketName=' +
          encodeURIComponent(bucket) + '&docId=' + encodeURIComponent(id);
        callback();
      }, function(err) {
        if (err.error === 'conflict') {
          document.location.href = '#sec=edit_doc&bucketName=' +
            encodeURIComponent(bucket) + '&docId=' + encodeURIComponent(id);
          callback();
        } else {
          alertDialog('Unknown error saving document');
        }
      });
    }

    function lookupDocument(id) {

      if (id === '') {
        alertDialog('Document ID cannot be empty');
        return;
      }

      couchReq('GET', buildDocURL(self.dbUrlCell.value, id), null, function() {
        lookupInp.val('');
        document.location.href = '#sec=edit_doc&bucketName=' +
          encodeURIComponent(self.bucketName) + '&docId=' + encodeURIComponent(id);
      }, function() {
        alertDialog('Document was not found');
      });

    }


    $('#documents .header_2 a.btn_create').click(function(){
      showDialog('create_document_dialog', {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          createDoc(self.bucketName, $('#new_doc_id').val(), function() {
            $('#new_doc_id').val('');
          });
        }]]
      });
    });

    // This shouldnt exist, just passing from allDocs cell into subscribe
    self.bucketName;

    self.dbUrlCell = Cell
      .needing(DAL.cells.capiBase, DocumentsModel.documentsBucketCell)
      .compute(function (v, baseUri, bucketName) {
        self.bucketName = bucketName;
        return buildURL(baseUri, bucketName) + "/";
      });

    var currentPage = 0;
    var limit = 5;
    var total = 0;

    var prevBtn = $('#documents .arr_prev');
    var nextBtn = $('#documents .arr_next');
    var lookupBtn = $('#docs_lookup_doc_by_id_btn');
    var lookupInp = $('#docs_lookup_doc_by_id');

    self.allDocs = Cell
      .needing(self.dbUrlCell)
      .compute(function (v, dbUrl) {
        var params = '?limit=' + limit + '&skip=' + (currentPage * limit);
        renderTemplate('documents_list', {loading: true});
        return future.get({url: dbUrl + '_all_docs' + params});
      });


    self.allDocs.subscribe(function (cell, x) {

      total = cell.value.total_rows;
      var lastPage = Math.max(0, Math.ceil(total / limit) - 1);
      if (currentPage > lastPage) {
        currentPage = lastPage;
      }

      if (total > 0) {
        lookupInp.removeAttr('disabled');
      } else {
        lookupInp.attr('disabled', 'disabled');
      }

      lookupBtn.toggleClass('disabled', !(total > 0));
      prevBtn.toggleClass('disabled', currentPage === 0);
      nextBtn.toggleClass('disabled', currentPage > lastPage - 1);

      renderTemplate('documents_list', {
        loading: false,
        rows: cell.value.rows,
        bucketName: self.bucketName
      });
    });

    (function () {

      function pageBtnClicker(btn, increment) {
        btn.click(function (ev) {
          if (btn.hasClass('disabled')) {
            return;
          }
          ev.preventDefault();
          currentPage = currentPage + increment;
          self.allDocs.invalidate();
        });
      }

      pageBtnClicker(prevBtn, -1);
      pageBtnClicker(nextBtn, 1);

      lookupBtn.live('mousedown', function(e) {
        if (lookupBtn.hasClass('disabled')) {
          return;
        }
        e.preventDefault();
        lookupDocument(lookupInp.val());
      });

    })();

  },
  onEnter: function () {
    this.allDocs.invalidate();
  },
  navClick: function () {
  }
};


var EditDocumentSection = {

  init: function() {

    var self = this;

    self.docIdVal;
    self.docRevVal;

    var bucketName = self.bucketName = DocumentsModel.bucketName;
    var docId = self.docId = new StringHashFragmentCell("docId");

    function saveDoc(id, rev, callback) {

      try {
        var json = JSON.parse(self.jsonCodeEditor.getValue());
      } catch(err) {
        alertDialog('Document is invalid JSON');
        return;
      }

      for (var key in json) {
        if (/^(\$|_)/.test(key)) {
          delete json[key];
        }
      }

      json._id = id;
      if (rev) {
        json._rev = rev;
      }

      $('#doc_save').addClass('disabled').find('span').text("Saving");

      couchReq('PUT', buildDocURL(self.dbUrl.value, id), json,
               function(data) {
        $('#doc_save').removeClass('disabled').find('span').text("Save");
        self.docIdVal = data.id;
        self.docRevVal = data.rev;
        callback();
      }, function() {
        $('#doc_save').removeClass('disabled').find('span').text("Save");
        alertDialog('Unknown error saving document');
      });
    }


    function deleteDoc() {
      var obj = {_id: self.docIdVal, _rev: self.docRevVal};
      var url = buildDocURL(self.dbUrl.value, self.docIdVal,
                         {rev: self.docRevVal});
      couchReq('DELETE', url, null, function(data) {
        document.location.hash = 'sec=documents&bucketName='
          + encodeURIComponent(self.bucketName.value);
      }, function() {
        alertDialog('Unknown error saving document');
      });
    }

    var dbUrl = self.dbUrl = Cell
    .needing(DAL.cells.capiBase, bucketName)
    .compute(function (v, baseUri, bucketName) {
      return baseUri + bucketName;
    });

    var currentDoc = self.currentDoc = Cell
      .needing(dbUrl, docId)
      .compute(function (v, dbUrl, docId) {
        self.docIdVal = docId;
        return future.get({url: buildDocURL(dbUrl, docId)});
      });

    self.jsonCodeEditor = CodeMirror.fromTextArea($("#json_doc")[0], {
      lineNumbers: true,
      matchBrackets: true,
      mode: {name: "javascript", json: true},
      theme: 'default'
    });

    // subscriptions
    bucketName.subscribeValue(function (bucket) {
      $('#doc_buckets_select + a').attr('href', '#sec=documents&bucketName='
        + encodeURIComponent(bucket));
    });

    currentDoc.subscribeValue(function (doc) {
      if (doc === undefined) {
        return;
      } else {
        self.docRevVal = doc._rev;
        self.jsonCodeEditor.setValue(JSON.stringify(doc, null, "  "));
        $('#json_doc_id').text(doc._id);
        // We no longer have metadata to test for non json documents, for
        // now just test attachments
        if(typeof doc._attachments === 'undefined') {
          self.jsonCodeEditor.setOption('readOnly', false);
          $('#doc_saveas').removeClass('disabled');
          $('#doc_save').removeClass('disabled');
          $('#editing-notice').text('');
        } else {
          $('#editing-notice').text('(Editing disabled for non JSON documents)');
          self.jsonCodeEditor.setOption('readOnly', 'nocursor');
          $('#doc_saveas').addClass('disabled');
          $('#doc_save').addClass('disabled');
        }
      }
    });

    $('#doc_buckets_select').live('change', function() {
      docId.setValue("");
      ThePage.gotoSection('documents');
    });
    $('#doc_delete:not(.disabled)').live('click', deleteDoc);
    $('#doc_save:not(.disabled)').live('click', function() {
      saveDoc(self.docIdVal, self.docRevVal, function() {});
    });

    $('#doc_saveas:not(.disabled)').live('click', function(ev) {
      showDialog('save_documentas_dialog', {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          var id = $('#saveas_id').val();
          saveDoc(id, null, function() {
            $('#saveas_id').val('');
            document.location.hash = 'sec=edit_doc&bucketName=' +
              encodeURIComponent(self.bucketName.value) +
              '&docId=' + encodeURIComponent(id);
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
