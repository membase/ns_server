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

 var documentErrors = {
  '502': '(The node containing that document is currently down)',
  '503': '(The data has not yet loaded, please wait...)',
  idEmpty: 'Document ID cannot be empty',
  notExist: '(Document does not exist)',
  unexpected: '(Unexpected error)',
  invalidJson: '(Document is invalid JSON)',
  alreadyExists: 'Document with given ID already exists',
  bucketNotExist: 'Bucket does not exist',
  bucketListEmpty: 'Buckets list empty'
 }

function createDocumentsCells(ns, modeCell, capiBaseCell, bucketsListCell) {
  //bucket
  ns.populateBucketsDropboxCell = Cell.compute(function (v) {
    var mode = v.need(modeCell);
    if (mode != 'documents') {
      return;
    }
    var buckets = v.need(bucketsListCell).byType.membase;
    var selectedBucketName = v.need(ns.selectedBucketCell);
    return {
      list: _.map(buckets, function (info) { return [info.name, info.name] }),
      selected: selectedBucketName
    };
  }).name("populateBucketsDropboxCell");

  ns.selectedBucketCell = Cell.compute(function (v) {
    var section = v.need(modeCell);
    if (section != 'documents') {
      return;
    }
    var selected = v(ns.bucketNameCell);
    var buckets = v.need(bucketsListCell).byType.membase;

    if (selected) {
      var bucketNotExist = !_.detect(buckets, function (info) { return info.name === selected });
      if (bucketNotExist) {
        return null;
      } else {
        return selected;
      }
    } else {
      var bucketInfo = _.detect(buckets, function (info) { return info.name === "default" }) || buckets[0];
      if (bucketInfo) {
        return bucketInfo.name;
      } else {
        return null;
      }
    }
  }).name("selectedBucketCell");
  ns.selectedBucketCell.equality = function (a, b) {return a === b;};

  ns.haveBucketsCell = Cell.compute(function (v) {
    return v.need(ns.selectedBucketCell) !== null;
  });

  //document
  ns.currentDocumentIdCell = Cell.compute(function (v) {
    var docId = v(ns.documentIdCell);
    if (docId) {
      return decodeURIComponent(docId);
    }
    return null;
  }).name("currentDocumentIdCell");

  ns.currentDocURLCell = Cell.compute(function (v) {
    var currentDocId = v(ns.currentDocumentIdCell);
    if (currentDocId) {
      return buildDocURL(v.need(ns.dbURLCell), currentDocId);
    }
  }).name("currentDocURLCell");

  ns.rawCurrentDocCell = Cell.compute(function (v) {
    var dataCallback;

    return future.get({
      url: v.need(ns.currentDocURLCell),
      error: function (xhr) {
        var error = new Error(xhr.statusText);
        switch (xhr.status) {
          case '502':
            error.explanatoryMessage = documentErrors['502'];
            break;
          case '503':
            error.explanatoryMessage = documentErrors['503'];
            break;
          default:
            try {
              JSON.parse(xhr.responseText);
              error.explanatoryMessage = documentErrors.unexpected;
            } catch (jsonError) {
              jsonError.explanatoryMessage = documentErrors.invalidJson;
              dataCallback(jsonError);
              return;
            }
            break;
        }
        dataCallback(error);
      },
      success: function (doc, status) {
        if (doc) {
          dataCallback(doc);
        } else {
          var error = new Error(status);
          error.explanatoryMessage = documentErrors.notExist;
          dataCallback(error);
        }
      }}, undefined, undefined, function (initXHR) {
        return future(function (__dataCallback) {
          dataCallback = __dataCallback;
          initXHR(dataCallback);
        });
      }
    );
  }).name('rawCurrentDocCell');

  ns.currentDocCell = Cell.compute(function (v) {
    if (v.need(ns.haveBucketsCell)) {
      return v.need(ns.rawCurrentDocCell);
    } else {
      var error = new Error('not found');
      error.explanatoryMessage = documentErrors.notExist;
      return error;
    }
  }).name("currentDocCell");

  ns.currentDocCell.delegateInvalidationMethods(ns.rawCurrentDocCell);

  //documents list
  ns.currentPageDocsURLCell = Cell.compute(function (v) {
    var currentDocId = v(ns.currentDocumentIdCell);
    if (currentDocId) {
      return;
    }
    var param = {};
    var page = v.need(ns.currentDocumentsPageNumberCell);
    var limit = v(ns.currentPageLimitCell);
    var searchTerm = v(ns.searchedDocumentCell);
    var skip = page * limit;

    param.skip = String(skip);

    if (searchTerm) {
      param.limit = String(limit + 1);
      param.startkey = JSON.stringify(searchTerm);
      param.endkey = JSON.stringify(searchTerm + String.fromCharCode(0xffff));
    } else {
      param.limit = String(limit);
    }

    return buildURL(v.need(ns.dbURLCell), "_all_docs", param);
  }).name("currentPageDocsURLCell");

  ns.currentPageDocsCell = Cell.compute(function (v) {
    if (v.need(ns.haveBucketsCell)) {
      //should we catch errors for GET documents list ?
      return future.get({url: v.need(ns.currentPageDocsURLCell)});
    } else {
      return {rows: [], total_rows: 0};
    }
  }).name("currentPageDocsCell");

  ns.dbURLCell = Cell.compute(function (v) {
    var base = v.need(capiBaseCell);
    var bucketName = v.need(ns.selectedBucketCell);

    if (bucketName) {
      return buildURL(base, bucketName) + "/";
    }
  }).name("dbURLCell");

  ns.currentPageLimitCell = Cell.compute(function (v) {
    var pageLimit = v(ns.pageLimitCell);
    if (pageLimit) {
      return pageLimit;
    }
    return 5;
  });

  ns.currentDocumentsPageNumberCell = Cell.compute(function (v) {
    var page = v(ns.documentsPageNumberCell);
    page = Number(page);
    if (page) {
      return page;
    } else {
      return 0;
    }
  }).name('currentDocumentsPageNumberCell');
}

var DocumentsSection = {
  init: function () {
    var self = this;

    self.bucketNameCell = new StringHashFragmentCell("bucketName");
    self.documentsPageNumberCell = new StringHashFragmentCell("documentsPageNumber");
    self.documentIdCell = new StringHashFragmentCell("docId");
    self.searchedDocumentCell = new Cell();
    self.pageLimitCell = new Cell();

    createDocumentsCells(self, DAL.cells.mode, DAL.cells.capiBase, DAL.cells.bucketsListCell);

    var documents = $('#documents');

    var createDocDialog = $('#create_document_dialog');
    var createDocWarning = $('.warning', createDocDialog);
    var createDocInput = $('#new_doc_id', createDocDialog);
    var deleteDocDialog = $("#delete_document_confirmation_dialog");
    var deleteDocDialogWarning = $('.error', deleteDocDialog);

    var breadCrumpDoc = $('#bread_crump_doc', documents);
    var prevNextCont  = $('.ic_prev_next', documents);
    var prevBtn = $('.arr_prev', documents);
    var nextBtn = $('.arr_next', documents);
    var allDocsCont = $('.shadow_box', documents);
    var currenDocCont = $('#documents_details', documents);
    var editingNotice = $('#editing-notice');
    var jsonDocId = $('#json_doc_id', documents);
    var docsLookup = $('#docs_lookup_doc_by_id', documents);
    var docsLookupBtn = $('#docs_lookup_doc_by_id_btn', documents);
    var docDeleteBtn = $('#doc_delete', documents);
    var docSaveAsBtn = $('#doc_saveas', documents);
    var docSaveBtn = $('#doc_save', documents);
    var docCreateBtn = $('.btn_create', documents);
    var docsBucketsSelect = $('#docs_buckets_select', documents);
    var lookupDocForm = $('#search_doc', documents);

    self.jsonCodeEditor = CodeMirror.fromTextArea($("#json_doc")[0], {
      lineNumbers: true,
      matchBrackets: false,
      tabSize: 2,
      mode: { name: "javascript", json: true },
      theme: 'default',
      readOnly: 'nocursor',
      onKeyEvent: function (doc) {
        onDocValueUpdate(doc.getValue());
      }
    });

    var documentsDetails = $('#documents_details');
    var codeMirror = $(".CodeMirror", documentsDetails);

    _.each([prevBtn, nextBtn, docsLookupBtn, docDeleteBtn, docSaveAsBtn, docSaveBtn, docCreateBtn], function (btn) {
      btn.click(function (e) {
        if ($(this).hasClass('disabled')) {
          e.stopImmediatePropagation();
        }
      })
    });

    function showDocumentListState(page) {
      prevBtn.toggleClass('disabled', page.pageNumber === 0);
      nextBtn.toggleClass('disabled', isLastPage(page));

      showDocumentState(false);

      renderTemplate('documents_list', {
        loading: false,
        rows: page.docs.rows,
        pageNumber: page.pageNumber,
        bucketName: page.bucketName
      });
    }

    function isLastPage(page) {
      if (page.isLookupList) {
        return page.docs.rows.length <= page.pageLimit ? true : !page.docs.rows.pop();
      } else {
        return page.docs.rows.length < page.pageLimit ? true : (page.pageLimit * (page.pageNumber + 1)) >= page.docs.total_rows;
      }
    }

    function showCodeEditor(show) {
      self.jsonCodeEditor.setOption('readOnly', show ? false : 'nocursor');
      self.jsonCodeEditor.setOption('matchBrackets', show ? true : false);
      $(self.jsonCodeEditor.getWrapperElement())[show ? 'removeClass' : 'addClass']('read_only');
    }

    function showDocumentState(show) {
      showPrevNextCont(!show);
      allDocsCont[show ? 'hide' : 'show']();
      currenDocCont[show ? 'show' : 'hide']();
      showCodeEditor(!show);
    }

    function bucketExistsState(exists) {
      enableLookup(exists);
      enableDeleteBtn(exists);
      showPrevNextCont(exists);
    }

    function enableSaveBtns(enable) {
      docSaveBtn[enable ? 'removeClass' : 'addClass']('disabled');
      docSaveAsBtn[enable ? 'removeClass' : 'addClass']('disabled');
    }

    function enableLookup(enable) {
      docsLookup.attr({disabled: !enable});
      docsLookupBtn[enable ? 'removeClass' : 'addClass']('disabled');
    }

    function enableDeleteBtn(enable) {
      docDeleteBtn[enable ? 'removeClass' : 'addClass']('disabled');
    }

    function showPrevNextCont(show) {
      prevNextCont[show ? 'show' : 'hide']();
    }

    function tryShowJson(obj) {
      var isError = obj instanceof Error;

      editingNotice.text(isError && obj ? buildErrorMessage(obj) : '');
      jsonDocId.text(isError ? '' : obj._id);
      self.jsonCodeEditor.setValue(isError ? '' : JSON.stringify(obj, null, "  "));
      enableDeleteBtn(!isError);
      enableSaveBtns(!isError);
      showCodeEditor(!isError);
    }

    function onDocValueUpdate(json) {
      enableSaveBtns(true);
      editingNotice.text('');
      try {
        var parsedJSON = JSON.parse(json);
      } catch (error) {
        enableSaveBtns(false);
        enableDeleteBtn(true);
        error.explanatoryMessage = documentErrors.invalidJson;
        editingNotice.text(buildErrorMessage(error));
        return false;
      }
      return parsedJSON;
    }

    function buildErrorMessage(error) {
      return error.name + ': ' + error.message + ' ' + error.explanatoryMessage;
    }

    (function () {
      var page = {};
      var prevPage;
      var nextPage;

      Cell.subscribeMultipleValues(function (docs, currentPage, selectedBucket, pageLimit, searchedDoc) {
        if (typeof currentPage === 'number') {
          prevPage = currentPage - 1;
          prevPage = prevPage < 0 ? 0 : prevPage;
          nextPage = currentPage + 1;
          page.pageLimit = pageLimit;
          page.pageNumber = currentPage;
          page.isLookupList = !!searchedDoc;
        }
        if (docs) {
          page.docs = docs;
          page.bucketName = selectedBucket;
          showDocumentListState(page);
        } else {
          renderTemplate('documents_list', {loading: true});
          if (searchedDoc) {
            // we don't know number of matches. that's why we can't allow user to quick clicks on next button
            nextBtn.toggleClass('disabled', true);
          }
        }
      },
        self.currentPageDocsCell, self.currentDocumentsPageNumberCell, self.selectedBucketCell,
        self.currentPageLimitCell, self.searchedDocumentCell
      );

      nextBtn.click(function (e) {
        if (!page.isLookupList && isLastPage(page)) {
          return;
        }
        self.documentsPageNumberCell.setValue(nextPage);
      });

      prevBtn.click(function (e) {
        self.documentsPageNumberCell.setValue(prevPage);
      });

    })();

    self.searchedDocumentCell.subscribeValue(function (searchedDoc) {
      //for self.searchedDocumentCell.setValue(undefined)
      if (!searchedDoc) {
        docsLookup.val('');
      }
    });

    self.currentDocCell.subscribeValue(function (doc) {
      if (!doc) {
        return;
      }
      showDocumentState(true);
      tryShowJson(doc);
    });

    self.selectedBucketCell.subscribeValue(function (selectedBucket) {
      bucketExistsState(!!selectedBucket);
    });

    lookupDocForm.submit(function (e) {
      e.preventDefault();
      var docsLookupVal = $.trim(docsLookup.val());
      if (docsLookupVal) {
        self.documentIdCell.setValue(docsLookupVal);
      }
    });

    breadCrumpDoc.click(function (e) {
      e.preventDefault();
      self.documentIdCell.setValue(undefined);
      self.currentPageDocsCell.invalidate();
    });

    docsBucketsSelect.bindListCell(self.populateBucketsDropboxCell, {
      onChange: function (e, newValue) {
        self.bucketNameCell.setValue(newValue);
        self.documentsPageNumberCell.setValue(undefined);
        self.documentIdCell.setValue(undefined);
      },
      onRenderDone: function (input, args) {
        if (args.list.length == 0) {
          input.val(documentErrors.bucketListEmpty);
        }
        if (args.selected === null) {
          input.val(documentErrors.bucketNotExist);
          input.css('color', '#C00');
        }
      }
    });

    (function(){
      var latestSearch;
      self.searchedDocumentCell.subscribeValue(function (term) {
        latestSearch = term;
      });
      docsLookup.keyup(function (e) {
        var docsLookupVal = $.trim($(this).val());
        if (latestSearch === docsLookupVal) {
          return true;
        }
        self.searchedDocumentCell.setValue(docsLookupVal);
        self.documentsPageNumberCell.setValue(0);
      });
    })();

    //CRUD
    (function () {
      var modal;
      var spinner;
      var dbURL;
      var currentDocUrl;

      self.dbURLCell.subscribeValue(function (url) {;
        dbURL = url;
      });

      self.currentDocURLCell.subscribeValue(function (url) {
        currentDocUrl = url;
      });

      function startSpinner(dialog) {
        modal = new ModalAction();
        spinner = overlayWithSpinner(dialog);
      }

      function stopSpinner() {
        modal.finish();
        spinner.remove();
      }

      function checkOnExistence(newUrl, preDefDoc) {
        couchReq("GET", newUrl, null,
          function (doc) {
            if (doc) {
              createDocWarning.text(documentErrors.alreadyExists).show();
            }
          },
          function (error) {
            startSpinner(createDocDialog);
            couchReq("PUT", newUrl, preDefDoc, function () {
              stopSpinner();
              hideDialog(createDocDialog);
              self.documentIdCell.setValue(preDefDoc._id);
            }, function (error, num, unexpected) {
              if (error.reason) {
                stopSpinner();
                createDocWarning.text(error.reason).show();
              } else {
                unexpected();
              }
              self.currentPageDocsURLCell.recalculate();
            });
          }
        );
      }

      docCreateBtn.click(function (e) {
        e.preventDefault();
        createDocWarning.text('');

        showDialog(createDocDialog, {
          eventBindings: [['.save_button', 'click', function (e) {
            e.preventDefault();
            var val = $.trim(createDocInput.val());
            if (val) {
              var preDefinedDoc = {_id: val};
              var newDocUrl = buildDocURL(dbURL, val);
              checkOnExistence(newDocUrl, preDefinedDoc);
            } else {
              createDocWarning.text(documentErrors.idEmpty).show();
            }
          }]]
        });
      });

      docSaveAsBtn.click(function (e) {
        e.preventDefault();
        createDocWarning.text('');

        showDialog(createDocDialog, {
          eventBindings: [['.save_button', 'click', function (e) {
            e.preventDefault();
            var json = onDocValueUpdate(self.jsonCodeEditor.getValue());
            if (json) {
              var val = $.trim(createDocInput.val());
              if (val) {
                var preDefinedDoc = json;
                preDefinedDoc._id = val;
                var newDocUrl = buildDocURL(dbURL, val);
                checkOnExistence(newDocUrl, preDefinedDoc);
              } else {
                createDocWarning.text(documentErrors.idEmpty).show();
              }
            } else {
              hideDialog(createDocDialog);
            }
          }]]
        });
      });

      docSaveBtn.click(function (e) {
        e.preventDefault();
        editingNotice.text('');
        var json = onDocValueUpdate(self.jsonCodeEditor.getValue());
        if (json) {
          startSpinner(codeMirror);
          enableSaveBtns(false);
          enableDeleteBtn(false);
          couchReq('PUT', currentDocUrl, json, function () {
            couchReq("GET", currentDocUrl, undefined, function (doc) {
              self.jsonCodeEditor.setValue(JSON.stringify(doc, null, "  "));
              stopSpinner();
              enableDeleteBtn(true);
              enableSaveBtns(true);
            });
          }, function (error, num, unexpected) {
            if (error.reason) {
              stopSpinner();
              editingNotice.text(error.reason).show();
            } else {
              unexpected();
            }
          });
        }
      });

      docDeleteBtn.click(function (e) {
        e.preventDefault();
        deleteDocDialogWarning.text('').hide();
        showDialog(deleteDocDialog, {
          eventBindings: [['.save_button', 'click', function (e) {
            e.preventDefault();
            startSpinner(deleteDocDialog);
            //deletion of non json document leads to 409 error
            couchReq('DELETE', currentDocUrl, null, function () {
              stopSpinner();
               hideDialog(deleteDocDialog);
              self.documentIdCell.setValue(undefined);
              self.currentPageDocsCell.recalculate();
            }, function (error, num, unexpected) {
              if (error.reason) {
                stopSpinner();
                deleteDocDialogWarning.text(error.reason).show();
              } else {
                unexpected();
              }
            });
          }]]
        });
      });
    })();
  },
  onLeave: function () {
    var self = this;
    self.documentsPageNumberCell.setValue(undefined);
    self.searchedDocumentCell.setValue(undefined);
  },
  onEnter: function () {
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  }
};
