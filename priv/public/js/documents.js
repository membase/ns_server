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
  invalidDoc: '(Invalid document)',
  alreadyExists: 'Document with given ID already exists',
  bucketNotExist: 'Bucket does not exist',
  bucketListEmpty: 'Buckets list empty',
  documentLimitError: "Editing of document with size more than 2.5kb is not allowed",
  documentIsBase64: "Editing of binary document is not allowed",
  shouldNotBeNull: "JSON object cannot be null",
  shouldBeAnObject: "JSON should represent an object",
  shouldNotBeAnArray: "JSON should not be an array"
};

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
      return docId;
    }
    return null;
  }).name("currentDocumentIdCell");

  ns.selectedBucketCRUDBaseCell = Cell.compute(function (v) {
    var currentBucket = v.need(ns.selectedBucketCell);
    return buildURL("/pools/default/buckets/", currentBucket, "docs");
  });

  ns.currentDocURLCell = Cell.compute(function (v) {
    var currentDocId = v(ns.currentDocumentIdCell);
    if (currentDocId) {
      return buildURL(v.need(ns.selectedBucketCRUDBaseCell) + "/", currentDocId);
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
              error.explanatoryMessage = documentErrors.unexpected;
            break;
        }
        dataCallback(error);
      },
      success: function (doc, status, xhr) {
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
      });
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
    var param = _.extend({}, v(ns.filter.filterParamsCell));
    var page = v.need(ns.currentDocumentsPageNumberCell);
    var limit = v(ns.currentPageLimitCell);
    var skip = page * limit;

    param.skip = String(skip);
    param.include_docs = true;
    param.limit = String(limit + 1);

    if (param.startkey) {
      param.startkey = JSON.stringify(param.startkey);
    }

    if (param.endkey) {
      param.endkey = JSON.stringify(param.endkey);
    }

    return buildURL(v.need(ns.selectedBucketCRUDBaseCell), param);
  }).name("currentPageDocsURLCell");

  ns.currentPageDocsCell = Cell.compute(function (v) {
    if (v.need(ns.haveBucketsCell)) {
      return future.capiViewGet({url: v.need(ns.currentPageDocsURLCell)});
    } else {
      return {rows: []};
    }
  }).name("currentPageDocsCell");

  ns.currentPageLimitCell = Cell.compute(function (v) {
    var pageLimit = v(ns.pageLimitCell);
    if (pageLimit) {
      return Number(pageLimit);
    }
    return 5;
  });

  ns.currentDocumentsPageNumberCell = Cell.compute(function (v) {
    var page = v(ns.documentsPageNumberCell);
    if (!page) {
      return 0;
    }
    page = Number(page);
    var pageLimit = v.need(ns.currentPageLimitCell);
    var docsLimit = ns.docsLimit;
    var currentSkip = (page + 1) * pageLimit;

    if (currentSkip > docsLimit) {
      page = (docsLimit / pageLimit) - 1;
    }

    return page;
  }).name('currentDocumentsPageNumberCell');
}

var DocumentsSection = {
  docsLimit: 1000,
  docBytesLimit: 2500,
  init: function () {
    var self = this;

    self.bucketNameCell = new StringHashFragmentCell("viewsBucket");
    self.documentsPageNumberCell = new StringHashFragmentCell("documentsPageNumber");
    self.documentIdCell = new StringHashFragmentCell("docId");
    self.pageLimitCell = new StringHashFragmentCell("documentsPageLimit");

    var documents = $('#js_documents');
    var allDocsCont = $('#documents_list', documents);
    var allDocsTitle = $('.docs_title', allDocsCont);

    self.filter = new Filter({
      prefix: 'documents',
      hashName: 'documentsFilter',
      appendTo: allDocsTitle
    }, {
      title: 'Documents Filter',
      prefix: 'documents',
      items: {
        inclusiveEnd: true,
        endkey: true,
        startkey: true
      }
    }).init();

    createDocumentsCells(self, DAL.cells.mode, DAL.cells.capiBase, DAL.cells.bucketsListCell);

    var createDocDialog = $('#create_document_dialog');
    var createDocWarning = $('.warning', createDocDialog);
    var createDocInput = $('#new_doc_id', createDocDialog);
    var deleteDocDialog = $("#delete_document_confirmation_dialog");
    var deleteDocDialogWarning = $('.error', deleteDocDialog);

    var breadCrumpDoc = $('#bread_crump_doc', documents);
    var prevNextCont  = $('.ic_prev_next', documents);
    var prevBtn = $('.arr_prev', documents);
    var nextBtn = $('.arr_next', documents);
    var currenDocCont = $('#documents_details', documents);
    var allDocsEditingNotice = $('.documents_notice', allDocsCont);
    var editingNotice = $('.documents_notice', currenDocCont);
    var jsonDocId = $('.docs_title', currenDocCont);
    var docsLookup = $('#docs_lookup_doc_by_id', documents);
    var docsLookupBtn = $('#docs_lookup_doc_by_id_btn', documents);
    var docDeleteBtn = $('#doc_delete', documents);
    var docSaveAsBtn = $('#doc_saveas', documents);
    var docSaveBtn = $('#doc_save', documents);
    var docCreateBtn = $('.btn_create', documents);
    var docsBucketsSelect = $('#docs_buckets_select', documents);
    var lookupDocForm = $('#search_doc', documents);
    var docsInfoCont = $('.docs_info', documents);
    var docsCrntPgCont = $('.docs_crnt_pg', documents);
    var itemsPerListWrap = $('.items_per_list_wrap', documents);
    var itemsPerList = $('select', itemsPerListWrap);
    var filterBtn = $('.filters_container', documents);

    allDocsEditingNotice.hide();
    editingNotice.hide();

    itemsPerList.selectBox();

    function jsonCodeEditorOnChange(doc) {
      if (isDocumentChanged(doc.historySize())) {
        enableSaveAsBtn(true);
        enableSaveBtn(true);
        onDocValueUpdate(doc.getValue());
      } else {
        enableSaveBtn(false);
      }
    }

    self.jsonCodeEditor = CodeMirror.fromTextArea($("#json_doc")[0], {
      lineNumbers: true,
      matchBrackets: false,
      tabSize: 2,
      mode: { name: "javascript", json: true },
      theme: 'default',
      readOnly: 'nocursor',
      onChange: jsonCodeEditorOnChange
    });

    var documentsDetails = $('#documents_details');
    var codeMirror = $(".CodeMirror", documentsDetails);

    _.each([prevBtn, nextBtn, docsLookupBtn, docDeleteBtn, docSaveAsBtn, docSaveBtn, docCreateBtn], function (btn) {
      btn.click(function (e) {
        if ($(this).hasClass('dynamic_disabled')) {
          e.stopImmediatePropagation();
        }
      })
    });

    function showDocumentListState(page) {
      prevBtn.toggleClass('dynamic_disabled', page.pageNumber === 0);
      nextBtn.toggleClass('dynamic_disabled', isLastPage(page));

      docsCrntPgCont.text(page.pageNumber + 1);

      var searchCriteria;
      self.filter.filterParamsCell.getValue(function (value) {
        searchCriteria = !$.isEmptyObject(value);
      });

      var errors = page.docs.errors && page.docs.errors[0];
      if (errors) {
        var error = new Error(errors.explain);
        error.explanatoryMessage = '(' + errors.reason + ')';
        showDocumetsListErrorState(error);
        renderTemplate('documents_list', {
          loading: false,
          rows: [],
          searchCriteria: searchCriteria,
          pageNumber: page.pageNumber,
          bucketName: page.bucketName
        });
      } else {
        if (page.docs.rows.length > page.pageLimit) {
          page.docs.rows.pop();
        }
        showDocumetsListErrorState(false);
        renderTemplate('documents_list', {
          loading: false,
          rows: page.docs.rows,
          searchCriteria: searchCriteria,
          pageNumber: page.pageNumber,
          bucketName: page.bucketName
        });

        $('.delete_btn', documents).click(function () {
          self.deleteDocument($(this).attr('data-id'));
        });
      }
    }

    function showDocumetsListErrorState(error) {
      var message = error ? buildErrorMessage(error) : '';
      if (message) {
        allDocsEditingNotice.text(message);
        allDocsEditingNotice.attr('title', JSON.stringify(message));
        allDocsEditingNotice.show();
      } else {
        allDocsEditingNotice.hide();
      }
      if (error) {
        self.documentsPageNumberCell.setValue(0);
      }
    }

    function isLastPage(page) {
      return page.docs.rows.length <= page.pageLimit || page.pageLimit * (page.pageNumber + 1) === self.docsLimit;
    }

    function isJsonOverLimited(json) {
      return getStringBytes(json) > self.docBytesLimit;
    }

    function isDocumentChanged(history) {
      return history.redo != 0 || history.undo != 0;
    }

    function showCodeEditor(show) {
      var show = !DAL.cells.isROAdminCell.value && show;
      self.jsonCodeEditor.setOption('readOnly', show ? false : 'nocursor');
      self.jsonCodeEditor.setOption('matchBrackets', show ? true : false);
      $(self.jsonCodeEditor.getWrapperElement())[show ? 'removeClass' : 'addClass']('read_only');
    }

    function showDocumentState(show) {
      showPrevNextCont(!show);
      showDocsInfoCont(!show);
      showItemsPerPage(!show);
      allDocsCont[show ? 'hide' : 'show']();
      currenDocCont[show ? 'show' : 'hide']();
      showCodeEditor(!show);
    }

    function showHideEditingNotice(notice) {
      var text = notice || '';
      editingNotice.toggle(!!notice);
      editingNotice.text(text);
      editingNotice.attr('title', text);
    }

    var documentSpinner;

    function showDocumentPendingState(show) {
      enableDeleteBtn(!show);
      enableSaveAsBtn(!show);
      showHideEditingNotice(false);
      if (show) {
        if (!documentSpinner) {
          documentSpinner = overlayWithSpinner(codeMirror);
        }
      } else {
        if (documentSpinner) {
          documentSpinner.remove();
          documentSpinner = undefined;
        }
      }
    }

    function bucketExistsState(exists) {
      enableLookup(exists);
      enableDocCreateBtn(exists);
      enableFilterBtn(exists);
    }

    function enableSaveBtn(enable) {
      docSaveBtn[enable ? 'removeClass' : 'addClass']('dynamic_disabled');
    }

    function enableSaveAsBtn(enable) {
      docSaveAsBtn[enable ? 'removeClass' : 'addClass']('dynamic_disabled');
    }

    function enableLookup(enable) {
      docsLookup.attr({disabled: !enable});
      docsLookupBtn[enable ? 'removeClass' : 'addClass']('dynamic_disabled');
    }

    function enableDocCreateBtn(enable) {
      docCreateBtn[enable ? 'removeClass' : 'addClass']('dynamic_disabled');
    }

    function enableFilterBtn(enable) {
      filterBtn[enable ? 'removeClass' : 'addClass']('dynamic_disabled');
    }

    function enableDeleteBtn(enable) {
      docDeleteBtn[enable ? 'removeClass' : 'addClass']('dynamic_disabled');
    }

    function showPrevNextCont(show) {
      prevNextCont[show ? 'show' : 'hide']();
    }

    function showItemsPerPage(show) {
      itemsPerListWrap[show ? 'show' : 'hide']();
    }

    function showDocsInfoCont(show) {
      docsInfoCont[show ? 'show' : 'hide']();
    }

    function generateWarning(message) {
      var warning = new Error(message);
      warning.name = "Warning";
      return warning;
    }

    function tryShowJson(obj) {
      var isError = obj instanceof Error;

      if (!isError && ("base64" in obj)) {
        tryShowJson(generateWarning(documentErrors.documentIsBase64));
        return;
      }

      if (!isError && isJsonOverLimited(JSON.stringify(obj.json))) {
        tryShowJson(generateWarning(documentErrors.documentLimitError));
        return;
      }

      enableSaveBtn(!isError);
      enableDeleteBtn(obj.message === documentErrors.documentIsBase64 || !isError);
      enableSaveAsBtn(!isError);
      showCodeEditor(!isError);

      showHideEditingNotice(isError && buildErrorMessage(obj));
      self.jsonCodeEditor.setOption("onChange", isError ? function () {} : jsonCodeEditorOnChange);
      self.jsonCodeEditor.setValue(isError ? '' : JSON.stringify(obj.json, null, "  "));
    }

    function parseJSON(json) {
      var parsedJSON = JSON.parse(json);
      if (parsedJSON == null) {
        throw generateWarning(documentErrors.shouldNotBeNull);
      }
      if (!_.isObject(parsedJSON)) {
        throw generateWarning(documentErrors.shouldBeAnObject);
      }
      if (_.isArray(parsedJSON)) {
        throw generateWarning(documentErrors.shouldNotBeAnArray);
      }
      return parsedJSON;
    }

    function onDocValueUpdate(json) {
      showHideEditingNotice(false);
      try {
        if (isJsonOverLimited(json)) {
          throw generateWarning(documentErrors.documentLimitError);
        }
        var parsedJSON = parseJSON(json);
      } catch (error) {
        enableSaveBtn(false);
        enableSaveAsBtn(false);
        enableDeleteBtn(true);
        error.explanatoryMessage = documentErrors.invalidDoc;
        showHideEditingNotice(buildErrorMessage(error));
        return false;
      }
      return parsedJSON;
    }

    function buildErrorMessage(error) {
      return error.name + ': ' + error.message + ' ' + (error.explanatoryMessage || '');
    }

    (function () {
      var page = {};
      var prevPage;
      var nextPage;
      var afterPageLoad;

      Cell.subscribeMultipleValues(function (docs, currentPage, selectedBucket, pageLimit) {
        if (typeof currentPage === 'number') {
          prevPage = currentPage - 1;
          prevPage = prevPage < 0 ? 0 : prevPage;
          nextPage = currentPage + 1;
          page.pageLimit = pageLimit;
          page.pageNumber = currentPage;
        }
        if (docs) {
          page.docs = docs;
          page.bucketName = selectedBucket;
          showDocumentListState(page);
          if (afterPageLoad) {
            afterPageLoad();
          }
        } else {
          renderTemplate('documents_list', {loading: true});
          // we don't know total rows. that's why we can't allow user to quick clicks on next button
          nextBtn.toggleClass('dynamic_disabled', true);
        }
      },
        self.currentPageDocsCell, self.currentDocumentsPageNumberCell, self.selectedBucketCell,
        self.currentPageLimitCell
      );

      self.currentPageLimitCell.subscribeValue(function (val) {
        itemsPerList.selectBox("value", val);
      });

      function prevNextCallback() {
        $('html, body').animate({scrollTop:0}, 250);
        afterPageLoad = undefined;
      }

      nextBtn.click(function (e) {
        self.documentsPageNumberCell.setValue(nextPage);
        afterPageLoad = prevNextCallback;
      });

      prevBtn.click(function (e) {
        self.documentsPageNumberCell.setValue(prevPage);
        afterPageLoad = prevNextCallback;
      });
    })();

    self.currentDocumentsPageNumberCell.subscribeValue(function (value) {
      docsCrntPgCont.text(value + 1);
    });

    self.currentDocumentIdCell.subscribeValue(function (docId) {
      showDocumentState(!!docId);
      if (docId) {
        jsonDocId.text(docId).attr({title: docId});
        showDocumentPendingState(true);
      }
    });

    self.pageLimitCell.getValue(function (value) {
      itemsPerList.selectBox('value', value);
    });

    self.currentDocCell.subscribeValue(function (doc) {
      if (!doc) {
        return;
      }
      showDocumentPendingState(false);
      tryShowJson(doc);
    });

    self.selectedBucketCell.subscribeValue(function (selectedBucket) {
      if (selectedBucket === undefined) {
        return;
      }
      self.filter.reset();
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
      self.filter.rawFilterParamsCell.setValue(undefined);
    });

    itemsPerList.change(function (e) {
      self.pageLimitCell.setValue(Number($(this).val()));
      self.documentsPageNumberCell.setValue(0);
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

    //CRUD
    (function () {
      var modal;
      var spinner;

      function startSpinner(dialog) {
        modal = new ModalAction();
        spinner = overlayWithSpinner(dialog);
      }

      function stopSpinner() {
        modal.finish();
        spinner.remove();
      }

      function tryCreatingDoc(docId, docJSON) {
        var newUrl = buildURL(self.selectedBucketCRUDBaseCell.value + "/", docId);

        couchReq("GET", newUrl, null, onGETSuccess, onGETError);
        return;

        function onGETSuccess(doc) {
          stopSpinner();
          createDocWarning.text(documentErrors.alreadyExists).show();
        }

        function onGETError(error, status, unexpected) {
          if (status >= 400 && status < 500) {
            doCreateDoc();
            return;
          }
          stopSpinner();
          if (error.reason) {
            createDocWarning.text(error.reason).show();
          } else {
            unexpected();
          }
        }

        function doCreateDoc() {
          couchReq("POST", newUrl, docJSON, onPOSTSuccess, onPOSTError);
        }

        function onPOSTSuccess() {
          stopSpinner();
          hideDialog(createDocDialog);
          self.documentIdCell.setValue(docId);
        }

        function onPOSTError(error, status, unexpected) {
          stopSpinner();
          if (error.reason) {
            createDocWarning.text(error.reason).show();
          } else {
            unexpected();
          }
          self.currentPageDocsURLCell.recalculate();
        }
      }

      docCreateBtn.click(function (e) {
        e.preventDefault();
        createDocWarning.text('');

        showDialog(createDocDialog, {
          eventBindings: [['.save_button', 'click', function (e) {
            e.preventDefault();
            var val = $.trim(createDocInput.val());
            if (val) {
              startSpinner(createDocDialog);
              var preDefinedDoc = {"click":"to edit",
                "new in 2.0":"there are no reserved field names"};
              tryCreatingDoc(val, preDefinedDoc);
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
                startSpinner(createDocDialog);
                tryCreatingDoc(val, json);
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
        showHideEditingNotice(false);
        var json = onDocValueUpdate(self.jsonCodeEditor.getValue());
        if (json) {
          enableSaveBtn(false);
          showDocumentPendingState(true);
          couchReq('POST', self.currentDocURLCell.value, json, function () {
            self.currentDocCell.setValue(undefined);
            self.currentDocCell.invalidate();
          }, function (error, status, unexpected) {
            showDocumentPendingState(false);
            enableSaveBtn(true);
            if (error.reason) {
              showHideEditingNotice(error.reason);
            } else {
              unexpected();
            }
          });
        }
      });

      self.deleteDocument = function (id, success) {
        deleteDocDialogWarning.text('').hide();
        showDialog(deleteDocDialog, {
          eventBindings: [['.save_button', 'click', function (e) {
            e.preventDefault();
            startSpinner(deleteDocDialog);
            couchReq('DELETE', buildURL(self.selectedBucketCRUDBaseCell.value + "/", id), null, function () {
              stopSpinner();
              hideDialog(deleteDocDialog);
              self.currentPageDocsCell.recalculate();
              if (success) {
                success();
              }
            }, function (error, num, unexpected) {
              stopSpinner();
              if (error.reason) {
                deleteDocDialogWarning.text(error.reason).show();
              } else {
                unexpected();
              }
            });
          }]]
        });
      }

      docDeleteBtn.click(function (e) {
        e.preventDefault();
        var currentDocId = self.currentDocumentIdCell.value;
        if (!currentDocId) {
          return;
        }
        self.deleteDocument(currentDocId, function () {
          self.documentIdCell.setValue(undefined);
        });
      });
    })();
  },
  onLeave: function () {
    var self = this;
    self.documentsPageNumberCell.setValue(undefined);
  },
  onEnter: function () {
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  }
};
