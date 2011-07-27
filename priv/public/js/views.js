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

// couch does redirect when doing _design%2FXX access, so we need special method
function buildDocURL(base, docId/*, ..args */) {
  var args = _.toArray(arguments);
  if (docId.slice(0, "_design/".length) === "_design/") {
    args.splice(1, 1, "_design", docId.slice("_design/".length));
  } else if (docId.slice(0, "_local/".length) === "_local/") {
    args.splice(1, 1, "_local", docId.slice("_local/".length));
  }
  return buildURL.apply(null, args);
}

function buildViewPseudoLink(bucketName, ddoc, viewName) {
  return encodeURIComponent([bucketName, ddoc._id, viewName].map(encodeURIComponent).join("/"));
}

function unbuildViewPseudoLink(link, body, context) {
  if (link.indexOf("/") < 0) {
    link = decodeURIComponent(link);
  }
  body = body || _.toArray;
  return body.apply(context, _.map(link.split("/"), decodeURIComponent));
}

function couchGet(url, callback) {
  IOCenter.performGet({url: url, dataType: "json", success: callback});
}

function couchReq(method, url, data, success, error) {
  $.ajax(url,
         {type: method,
          data: JSON.stringify(data),
          dataType: 'json',
          success: success,
          error: function (xhr) {
            var self = this;
            var args = arguments;
            var status = xhr.status;

            function handleUnexpected() {
              return onUnexpectedXHRError.apply(self, args);
            }

            if (status >= 500 || status < 400) {
              return handleUnexpected();
            }

            return error(JSON.parse(xhr.responseText), status,
                         handleUnexpected);
          }
         });
}

function isDevModeDoc(ddoc) {
  var devPrefix = "_design/$dev_";
  return ddoc._id.substring(0, devPrefix.length) == devPrefix;
}

var codeMirrorOpts = {
  lineNumbers: true,
    matchBrackets: true,
    mode: "javascript",
    theme: 'default'
};

var ViewsSection = {
  mapEditor: CodeMirror.fromTextArea($("#viewcode_map")[0], codeMirrorOpts),
  reduceEditor: CodeMirror.fromTextArea($("#viewcode_reduce")[0], codeMirrorOpts),
  ensureBucketSelected: function (bucketName, body) {
    var self = this;
    ThePage.ensureSection("views");
    Cell.waitQuiescence(function () {
      self.viewsBucketCell.getValue(function (actualBucketName) {
        if (actualBucketName === bucketName) {
          return body();
        }
        self.rawViewsBucketCell.setValue(bucketName);
        ensureBucket(bucketName, body);
      })
    });
  },
  init: function () {
    var self = this;
    var views = $('#views');

    // you can get to local cells through this for debugging
    self.initEval = function (arg) {
      return eval(arg);
    }

    self.modeTabs = new TabsCell("vtab",
                                 "#views .tabs",
                                 "#views .panes > div",
                                 ["production", "development"]);
    self.modeTabs.subscribeValue(function (tab) {
      views[tab == 'development' ? 'addClass' : 'removeClass']('in-development');
      views[tab == 'development' ? 'removeClass' : 'addClass']('in-production');
    });

    self.rawViewsBucketCell = new StringHashFragmentCell("viewsBucket");
    self.rawDDocIdCell = new StringHashFragmentCell("viewsDDocId");
    self.rawViewNameCell = new StringHashFragmentCell("viewsViewName");
    self.pageNumberCell = new StringHashFragmentCell("viewPage");

    self.viewsBucketCell = Cell.compute(function (v) {
      var selected = v(self.rawViewsBucketCell);
      if (selected) {
        return selected;
      }
      var buckets = v.need(DAL.cells.bucketsListCell);
      var bucketInfo = _.detect(buckets, function (info) {return info.name === "default"}) || buckets[0];
      if (!bucketInfo) {
        // TODO: handle empty buckets set
        return null;
      }
      return bucketInfo.name;
    });

    (function () {
      var cell = Cell.compute(function (v) {
        var mode = v.need(DAL.cells.mode);
        if (mode != 'views') {
          return;
        }

        var allBuckets = v.need(DAL.cells.bucketsListCell);
        var selectedBucketName = v.need(self.viewsBucketCell);
        return {list: _.map(allBuckets, function (info) {return [info.name, info.name]}),
                selected: selectedBucketName};
      });
      $('#views_bucket_select').bindListCell(cell, {
        onChange: function (e, newValue) {
          self.rawViewsBucketCell.setValue(newValue);
        }
      });
    })();

    var selectedBucketCell = self.selectedBucketCell = Cell.compute(function (v) {
      if (v.need(DAL.cells.mode) != 'views')
        return;
      return v.need(self.viewsBucketCell);
    }).name("selectedBucket");

    var dbURLCell = self.dbURLCell = Cell.compute(function (v) {
      var base = v.need(DAL.cells.capiBase);
      var bucketName = v.need(selectedBucketCell);
      return buildURL(base, bucketName) + "/";
    });

    (function (createBtn) {
      dbURLCell.subscribeValue(function (value) {
        createBtn.toggleClass('disabled', !value);
      });
      createBtn.bind('click', function (e) {
        e.preventDefault();
        ViewsSection.startCreateView();
      });
    })(views.find('.btn_create'));

    var allDDocsURLCell = Cell.compute(function (v) {
      return buildURL(v.need(dbURLCell), "_all_docs", {
        startkey: JSON.stringify("_design/"),
        endkey: JSON.stringify("_design0"),
        include_docs: "true"
      });
    }).name("allDDocsURL");

    var rawAllDDocsCell = Cell.compute(function (v) {
      return future.get({url: v.need(allDDocsURLCell)});
    }).name("rawAllDDocs");

    var allDDocsCell = self.allDDocsCell = Cell.compute(function (v) {
      return _.map(v.need(rawAllDDocsCell).rows, function (r) {return r.doc});
    }).name("allDDocs");
    allDDocsCell.delegateInvalidationMethods(rawAllDDocsCell);

    var currentDDocAndView = self.currentDDocAndView = Cell.computeEager(function (v) {
      var allDDocs = v.need(allDDocsCell);
      var ddocId = v(self.rawDDocIdCell);
      var viewName = v(self.rawViewNameCell);
      if (!ddocId || !viewName) {
        return [];
      }
      var ddoc = _.detect(allDDocs, function (d) {return d._id === ddocId});
      if (!ddoc) {
        return [];
      }
      var view = (ddoc.views || {})[viewName];
      if (!view) {
        return [];
      }
      return [ddoc, viewName];
    }).name("currentDDocAndView");

    (function () {
      var cell = Cell.compute(function (v) {
        var mode = v.need(DAL.cells.mode);
        if (mode != 'views') {
          return;
        }

        var bucketName = v.need(self.viewsBucketCell);

        var ddocs = v.need(allDDocsCell);
        var ddocAndView = v.need(currentDDocAndView);

        var selectedDDocId = ddocAndView.length && ddocAndView[0]._id;
        var selectedViewName = ddocAndView.length && ddocAndView[1];

        var groups = _.map(ddocs, function (doc) {
          var rv = "<optgroup label='" + escapeHTML(doc._id) + "'>";
          var viewNames = _.keys(doc.views || {}).sort();
          _.each(viewNames, function (name) {
            var maybeSelected = (selectedDDocId === doc._id && selectedViewName === name) ? ' selected' : '';
            rv += "<option value='" + escapeHTML(buildViewPseudoLink(bucketName, doc, name)) + "'" +
              maybeSelected + ">" +
              escapeHTML(name) + "</option>";
          });
          rv += "</optgroup>"
          return rv;
        });

        return {
          list: groups,
          selected: ddocAndView
        };
      });
      $('#views_view_select').bindListCell(cell, {
        onChange: function (e, newValue) {
          if (!newValue) {
            self.rawDDocIdCell.setValue(undefined);
            self.rawViewNameCell.setValue(undefined);
            return;
          }
          unbuildViewPseudoLink(newValue, function (_ignored, ddocId, viewName) {
            var devMode = isDevModeDoc({_id: ddocId});
            self.modeTabs.setValue(devMode ? 'development' : 'production');
            self.rawDDocIdCell.setValue(ddocId);
            self.rawViewNameCell.setValue(viewName);
          });
        },
        applyWidget: function () {},
        unapplyWidget: function () {},
        buildOptions: function (q, selected, list) {
          _.each(list, function (group) {
            var option = $(group);
            q.append(option);
          });
        }
      });
    })();

    DAL.subscribeWhenSection(currentDDocAndView, "views", function (value) {
      $('#views_spinner')[value ? 'hide' : 'show']();
      $('#views_list')[(value && !value.length) ? 'show' : 'hide']();
      $('#view_details')[(value && value.length) ? 'show' : 'hide']();
      if (value && value.length) {
        $('#preview_random_doc').trigger('click', true);
        self.mapEditor.refresh();
        self.reduceEditor.refresh();
      }
    });

    var currentView = self.currentView = Cell.compute(function (v) {
      return (function (ddoc, viewName) {
        if (viewName === undefined) {
          return;
        }
        return (ddoc.views || {})[viewName];
      }).apply(this, v.need(currentDDocAndView));
    }).name("currentView");

    (function () {

      var originalMap, originalReduce;

      currentView.subscribeValue(function (view) {

        $('#views .when-inside-view')[view ? 'show' : 'hide']();
        if (view === undefined) {
          return;
        }

        self.mapEditor.setValue(view.map);
        self.reduceEditor.setValue(view.reduce || "");

        originalMap = view.map;
        originalReduce = view.reduce || "";
      });

      var unchangedCell = new Cell();

      // TODO
      // renable the run button behaviour of disabling until save

      var onMapReduceChange = function () {
        var nowMap = self.mapEditor.getValue();
        var nowReduce = self.reduceEditor.getValue();
        var unchanged = (originalMap === nowMap && originalReduce === nowReduce);
        unchangedCell.setValue(unchanged);
      }

      // self.mapEditor.setOption('onChange', onMapReduceChange);
      // self.reduceEditor.setOption('onChange', onMapReduceChange);
      // unchangedCell.subscribeValue(function (unchanged) {
      //   $('#view_run_button').toggleClass('disabled', unchanged);
      // });

    })();

    function enableEditor(editor) {
      editor.setOption('readOnly', false);
      editor.setOption('lineNumbers', true);
      editor.setOption('matchBrackets', true);
    }

    function disableEditor(editor) {
      editor.setOption('readOnly', 'nocursor');
      editor.setOption('lineNumbers', false);
      editor.setOption('matchBrackets', false);
    }

    var editingDevView = Cell.compute(function (v) {
      var ddoc = v.need(currentDDocAndView)[0];
      if (!ddoc) {
        return false;
      }
      return !!ddoc._id.match(/^_design\/\$dev_/);
    }).name("editingDevView");

    editingDevView.subscribeValue(function (devView) {

      $('#save_view_as, #just_save_view')[devView ? "show" : "hide"]();

      if (!devView) {
        disableEditor(self.mapEditor);
        disableEditor(self.reduceEditor);
      } else {
        enableEditor(self.mapEditor);
        enableEditor(self.reduceEditor);
      }
    });

    var proposedViewResultsURLCell = Cell.compute(function (v) {
      if (!v(self.currentView)) {
        return;
      }
      var dbURL = v.need(self.dbURLCell);
      var ddocAndView = v.need(self.currentDDocAndView);
      if (!ddocAndView[1]) {
        return;
      }
      var filterParams = v.need(ViewsFilter.filterParamsCell);
      var pageVal = v(self.pageNumberCell);
      var pageNo = parseInt(pageVal, 10);
      if (isNaN(pageNo) || pageNo < 1) {
        pageNo = 1;
      }
      if (pageNo > 10) {
        pageNo = 10;
      }
      console.log("computing proposedViewResultsURLCell");
      return buildDocURL(dbURL, ddocAndView[0]._id, "_view", ddocAndView[1], _.extend({}, filterParams, {
        limit: "10",
        skip: String((pageNo - 1) * 10)
      }));
    }).name("proposedViewResultsURLCell");

    DAL.subscribeWhenSection(proposedViewResultsURLCell, "views", function (url) {
      if (url) {
        url = url.substr(url.indexOf('?'));
      } else {
        url = '';
      }
      $('#view_query_string').text(url);
    });

    var viewResultsURLCell = self.viewResultsURLCell = new Cell();
    viewResultsURLCell.runView = function () {
      viewResultsURLCell.setValue(undefined);
      Cell.waitQuiescence(function () {
        viewResultsURLCell.setValue(proposedViewResultsURLCell.value);
      });
    };

    proposedViewResultsURLCell.subscribeValue(function () {
      viewResultsURLCell.setValue(undefined);
    });

    var viewResultsCell = Cell.compute(function (v) {
      function missingValueProducer(xhr, options) {
        return {rows: [{key: JSON.parse(xhr.responseText)}]};
      }
      return future.get({url: v.need(viewResultsURLCell),
                         missingValueProducer: missingValueProducer});
    }).name("viewResultsCell");

    viewResultsCell.subscribeValue(function (value) {
      var rows = [];
      if (value) {
        rows = _.filter(value.rows, function (r) {return !!r.key});
      }
      renderTemplate('view_results', {rows: rows});
    });

    Cell.subscribeMultipleValues(function (url, results) {
      $('#view_results_container')[(url && !results) ? 'hide' : 'show']();
      $('#view_results_spinner')[(url && !results) ? 'show' : 'hide']();
    }, viewResultsURLCell, viewResultsCell);

    $('#save_view_as').bind('click', $m(self, 'startViewSaveAs'));
    $('#just_save_view').bind('click', $m(self, 'saveView'));

    var productionDDocsCell = Cell.compute(function (v) {
      var allDDocs = v.need(allDDocsCell);
      return _.select(allDDocs, function (ddoc) {
        return !isDevModeDoc(ddoc);
      });
    });

    var devDDocsCell = Cell.compute(function (v) {
      var allDDocs = v.need(allDDocsCell);
      return _.select(allDDocs, function (ddoc) {
        return isDevModeDoc(ddoc);
      });
    });

    function mkViewsListCell(ddocsCell, containerId) {
      var cell = Cell.needing(ddocsCell).compute(function (v, ddocs) {
        var bucketName = v.need(selectedBucketCell);
        var rv = _.map(ddocs, function (doc) {
          var rv = _.clone(doc);
          var viewInfos = _.map(rv.views || {}, function (value, key) {
            var plink = buildViewPseudoLink(bucketName, doc, key);
            return _.extend({name: key,
                             viewLink: '#showView=' + plink,
                             removeLink: '#removeView=' + plink
                            }, value);
          });
          viewInfos = _.sortBy(viewInfos, function (info) {return info.name});
          rv.viewInfos = viewInfos;
          return rv;
        });
        rv.bucketName = bucketName;
        return rv;
      });

      DAL.subscribeWhenSection(cell, "views", function (ddocs) {
        if (!ddocs)
          return;
        renderTemplate('views_list', {
          rows: ddocs,
          bucketName: ddocs.bucketName
        }, $i(containerId));
      });

      return cell;
    }

    var devDDocsViewCell = mkViewsListCell(devDDocsCell, 'development_views_list_container');
    var productionDDocsViewCell = mkViewsListCell(productionDDocsCell, 'production_views_list_container');

    $('#built_in_reducers a').bind('click', function (e) {
      var text = $(this).text();
      var reduceArea = $('#viewcode_reduce');
      if (reduceArea.prop('disabled')) {
        return;
      }
      self.reduceEditor.setValue(text || "");
    });

    (function () {
      var cancelCurrent;
      $('#view_details .sample-doc-block-expander').click(function(ev) {
        ev.stopPropagation();
        var jq = $('#sample_docs pre');

        if (cancelCurrent) {
          cancelCurrent();
        }

        if (jq.closest('.darker_block').hasClass('closed')) {
          jq.closest('.darker_block').removeClass('closed');
        } else {
          if (this.id !== 'preview_random_doc') {
            jq.closest('.darker_block').addClass('closed');
            return;
          }
        }

        jq.css('height', '100px');
        var spinner = overlayWithSpinner(jq);
        cancelCurrent = function () {
          cancelCurrent = null;
          spinner.remove();
          jq.css('height', '');
          if (timeoutId) {
            clearTimeout(timeoutId);
          }
        }
        var timeoutId = setTimeout(function () {
          cancelCurrent();
          var u = 2;
          var l = 0;
          var rand = Math.floor((Math.random() * (u-l+1))+l);
          jq.html($.futon.formatJSON(sampleDocs[rand], {html: true}));
        }, 500);
      });
    })();

    $('#view_run_button').bind('click', function (e) {
      if ($(this).hasClass('disabled')) {
        return;
      }
      e.preventDefault();
      self.runCurrentView();
    });

    var jsonCodeEditor = CodeMirror.fromTextArea($("#sample_doc_editor")[0], {
      lineNumbers: false,
      matchBrackets: false,
      mode: {name: "javascript", json: true},
      theme: 'default',
      readOnly: 'nocursor'
    });

    function fetchRandomId(fun) {
      couchReq('GET', '/couchBase/default/_random', null, function (data) {
        $.cookie("randomKey", data.id);
        fun(data.id);
      }, function() {
        jsonCodeEditor.setValue("Bucket is currently empty");
      });
    }

    function randomId(fun) {
      var stored = $.cookie("randomKey");
      if (stored) {
        fun(stored);
      } else {
        fetchRandomId(fun);
      }
    }

    function showDoc(id) {
      couchReq('GET', '/couchBase/default/' + id, null, function (data) {
        var tmp = JSON.stringify(data, null, "\t")
        jsonCodeEditor.setValue(tmp);
      }, function() {
        $.cookie("randomKey", "");
        randomId(showDoc);
      });
    }


    $('#preview_random_doc').bind('click', function(ev, dontReset) {
      if (typeof dontReset == "undefined") {
        $.cookie("randomKey", "");
      }
      randomId(showDoc);
    });


    $('#edit_preview_doc').click(function(ev) {
      ev.stopPropagation();
      $('#sample_docs').addClass('editing')
        .find('.darker_block').removeClass('closed');
      enableEditor(jsonCodeEditor);
    });


    $('#save_preview_doc').click(function(ev) {
      ev.stopPropagation();
      $('#sample_docs').removeClass('editing');
      var doc = jsonCodeEditor.getValue();
      // TODO: add JSON linting/parse error handling
     // TODO: add saving code
      jsonCodeEditor.setValue(doc);
      disableEditor(jsonCodeEditor);
    });
  },
  doDeleteDDoc: function (url, callback) {
    begin();
    function begin() {
      couchGet(url, withDoc);
    }
    function withDoc(ddoc) {
      if (!ddoc) {
        // 404
        callback(ddoc);
        return;
      }
      couchReq('DELETE',
               url + "?" + $.param({rev: ddoc._rev}),
               {},
               function () {
                 callback(ddoc);
               },
               function (error, status, handleUnexpected) {
                 if (status == 409) {
                   return begin();
                 }
                 return handleUnexpected();
               }
              );
    }
  },
  doSaveAs: function (dbURL, ddoc, toId, overwriteConfirmed, callback) {
    var toURL = buildDocURL(dbURL, toId);
    return begin();

    function begin() {
      couchGet(toURL, withDoc);
    }
    function withDoc(toDoc) {
      if (toDoc && !overwriteConfirmed) {
        return callback("conflict");
      }
      ddoc = _.clone(ddoc);
      ddoc._id = toId;
      if (toDoc) {
        ddoc._rev = toDoc._rev;
      } else {
        delete ddoc._rev;
      }
      //TODO: make sure attachments are not screwed
      couchReq('PUT',
               toURL,
               ddoc,
               function () {
                 callback("ok");
               },
               function (error, status, unexpected) {
                 if (status == 409) {
                   if (overwriteConfirmed) {
                     return begin();
                   }
                   return callback("conflict");
                 }
                 return unexpected();
               });
    }
  },
  withBucketAndDDoc: function (bucketName, ddocId, body) {
    var self = this;
    self.ensureBucketSelected(bucketName, function () {
      self.withDDoc(ddocId, body);
    });
  },
  withDDoc: function (id, body) {
    ThePage.ensureSection("views");
    var cell = Cell.compute(function (v) {
      var allDDocs = v.need(ViewsSection.allDDocsCell);
      var ddoc = _.detect(allDDocs, function (d) {return d._id == id});
      if (!ddoc) {
        return [];
      }
      var dbURL = v.need(ViewsSection.dbURLCell);
      return [buildDocURL(dbURL, ddoc._id), ddoc, dbURL];
    });
    cell.getValue(function (args) {
      if (!args[0]) {
        console.log("ddoc with id:", id, " not found");
      }
      args = args || [];
      body.apply(null, args);
    });
  },
  startDDocDelete: function (id) {
    this.withDDoc(id, function (ddocURL, ddoc) {
      if (!ddocURL) // no such doc
        return;

      showDialog('delete_designdoc_confirmation_dialog', {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          ViewsSection.allDDocsCell.setValue(undefined);
          var spinner = overlayWithSpinner("#delete_designdoc_confirmation_dialog");
          var action = new ModalAction();

          ViewsSection.doDeleteDDoc(ddocURL, function () {
            spinner.remove();
            action.finish();
            ViewsSection.allDDocsCell.recalculate();
            hideDialog('delete_designdoc_confirmation_dialog');
          });
        }]]
      });
    });
  },
  cutOffDesignPrefix: function (id) {
    return id.replace(/^_design\/(\$dev_|)/, "");
  },
  startDDocCopy: function (id) {
    this.withDDoc(id, function (ddocURL, ddoc, dbURL) {
      if (!ddocURL)
        return;

      var dialog = $('#copy_designdoc_dialog');
      var form = dialog.find("form");

      (function () {
        var name = ViewsSection.cutOffDesignPrefix(ddoc._id);
        var prefix = ddoc._id.slice(0, -(name.length));

        prefix = (prefix === "_design/") ? "_design/$dev_" : "_design/";

        setFormValues(form, {
          "ddoc_name": name,
          "prefix": prefix
        });
      })();

      var observer = form.observePotentialChanges(function () {
        var nameValue = form.find('.designdoc_name:not([disabled])').val();
        form.find('.designdoc_name[disabled]').val(nameValue);
        form.find('label').each(function () {
          var label = $(this);
          var checked = label.find(":radio").prop('checked');
          label.find('.designdoc_name').prop('disabled', !checked);
        });
      });

      showDialog(dialog, {
        onHide: function () {
          observer.stopObserving();
        },
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          var data = $.deparam(serializeForm(form));
          var toId = data.prefix + data.ddoc_name;
          var spinner = overlayWithSpinner($(dialog));
          var needReload = false;

          function closeDialog() {
            spinner.remove();
            hideDialog(dialog);
            if (needReload) {
              ViewsSection.allDDocsCell.recalculate();
            }
          }

          loop(false);

          function loop(overwriteConfirmed) {
            var modal = new ModalAction();
            ViewsSection.doSaveAs(dbURL, ddoc, toId, overwriteConfirmed, function (arg) {
              modal.finish();
              if (arg == "conflict") {
                genericDialog({text: "Please, confirm overwriting target design document.",
                               callback: function (e, name, instance) {
                                 instance.close();
                                 if (name != 'ok') {
                                   return closeDialog();
                                 }
                                 loop(true);
                               }});
                return;
              }
              if (arg != 'ok') BUG();
              needReload = true;
              closeDialog();
            });
          }
        }]]
      });
    });
  },
  doSaveView: function (dbURL, ddocId, viewName, overwriteConfirmed, callback, viewDef) {
    var ddocURL = buildDocURL(dbURL, ddocId);
    return begin();
    function begin() {
      couchGet(ddocURL, withDoc);
    }
    function withDoc(ddoc) {
      if (!ddoc) {
        ddoc = {_id: ddocId,
                views: {}};
      }
      var views = ddoc.views || (ddoc.views = {});
      if (views[viewName] && !overwriteConfirmed) {
        return callback("conflict");
      }
      views[viewName] = viewDef || {
        map: "function (doc) {\n  emit(doc._id, null);\n }"
      }
      couchReq('PUT',
               ddocURL,
               ddoc,
               function () {
                 callback("ok");
               },
               function (error, status, unexpected) {
                 if (status == 409) {
                   return begin();
                 }
                 return unexpected();
               });
    }
  },
  startCreateView: function (ddocId) {
    var dbURL = ViewsSection.dbURLCell.value;
    if (!dbURL) {
      return;
    }
    var dialog = $('#copy_view_dialog');
    var warning = dialog.find('.warning').hide();
    dialog.find('[name=designdoc_name], [name=view_name]').val('');
    var ddocNameInput = dialog.find('[name=designdoc_name]').need(1);
    ddocNameInput.prop('disabled', !!ddocId);
    if (ddocId) {
      ddocNameInput.val(this.cutOffDesignPrefix(ddocId));
    }
    showDialog(dialog, {
      title: 'Create View',
      closeOnEscape: false,
      eventBindings: [['.save_button', 'click', function (e) {
        e.preventDefault();
        startSaving(ddocNameInput.val(), dialog.find('[name=view_name]').val());
      }]]
    });

    function startSaving(ddocName, viewName) {
      if (!ddocName || !viewName) {
        warning.text("Design document and view names cannot be empty").show();
        return;
      }
      // TODO: maybe other validation
      var modal = new ModalAction();
      var spinner = overlayWithSpinner(dialog);
      ViewsSection.doSaveView(dbURL, "_design/$dev_" + ddocName, viewName, false, function (status) {
        var closeDialog = false;
        if (status == "conflict") {
          warning.text("View with given name already exists").show();
        } else {
          closeDialog = true;
        }
        modal.finish();
        spinner.remove();
        if (closeDialog) {
          ddocNameInput.prop('disabled', false);
          hideDialog(dialog);
          ViewsSection.allDDocsCell.recalculate();
          ViewsSection.modeTabs.setValue("development");
        }
      });
    }
  },
  doRemoveView: function (ddocURL, viewName, callback) {
    return begin();
    function begin() {
      couchGet(ddocURL, withDoc);
    }
    function withDoc(ddoc) {
      if (!ddoc) {
        return;
      }
      var views = ddoc.views || (ddoc.views = {});
      if (!views[viewName]) {
        return;
      }
      delete views[viewName];
      couchReq('PUT',
               ddocURL,
               ddoc,
               function () {
                 callback();
               },
               function (error, status, unexpected) {
                 if (status == 409) {
                   return begin();
                 }
                 return unexpected();
               });
    }
  },
  startRemoveView: function (pseudoLink) {
    return unbuildViewPseudoLink(pseudoLink, this.doStartRemoveView, this);
  },
  doStartRemoveView: function (bucketName, ddocId, viewName) {
    var self = this;
    self.withBucketAndDDoc(bucketName, ddocId, function (ddocURL, ddoc) {
      genericDialog({text: "Are you sure?",
                     callback: function (e, name, instance) {
                       instance.close();
                       if (name === 'ok') {
                         performRemove();
                       }
                     }});

      function performRemove() {
        self.allDDocsCell.setValue(undefined);
        self.doRemoveView(ddocURL, viewName, function () {
          self.allDDocsCell.recalculate();
        });
      }
    });
  },
  startViewSaveAs: function () {
    var self = this;
    var dialog = $('#copy_view_dialog');
    var warning = dialog.find('.warning').hide();

    Cell.compute(function (v) {
      var dbURL = v.need(self.dbURLCell);
      var pair = v.need(self.currentDDocAndView);
      return [dbURL].concat(pair);
    }).getValue(function (args) {
      begin.apply(self, args);
    });

    return;

    function begin(dbURL, ddoc, viewName) {
      if (viewName == null) {
        return;
      }

      var form = dialog.find('form');

      setFormValues(form, {
        'designdoc_name': self.cutOffDesignPrefix(ddoc._id),
        'view_name': viewName
      });

      showDialog(dialog, {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          var params = $.deparam(serializeForm(form));
          startSaving(dbURL, ddoc, viewName, params['designdoc_name'], params['view_name']);
        }]]
      });
    }

    var spinner;
    var modal;

    function startSaving(dbURL, ddoc, viewName, newDDocName, newViewName) {
      if (!newDDocName || !newViewName) {
        warning.text('Both design document name and view name need to be specified').show();
        return;
      }

      spinner = overlayWithSpinner(dialog);
      modal = new ModalAction();

      var newId = "_design/$dev_" + newDDocName;

      var mapCode = self.mapEditor.getValue();
      var reduceCode = self.reduceEditor.getValue();

      var view = ddoc.views[viewName];
      if (!view) BUG();
      view = _.clone(view);
      view.map = mapCode;
      if (reduceCode) {
        view.reduce = reduceCode;
      } else {
        delete view.reduce;
      }

      doSaveView(dbURL, newId, newViewName, view, ddoc._id === newId && newViewName === viewName);
    }

    function doSaveView(dbURL, ddocId, viewName, view, overwriteConfirmed) {
      return ViewsSection.doSaveView(dbURL, ddocId, viewName, overwriteConfirmed, callback, view);

      function callback(arg) {
        if (arg === "conflict") {
          return confirmOverwrite(dbURL, ddocId, viewName, view);
        }
        saveSucceeded(ddocId, viewName);
      }
    }

    function confirmOverwrite(dbURL, ddocId, viewName, view) {
      genericDialog({text: "Please, confirm overwriting exiting view.",
                     callback: function (e, name, instance) {
                       if (name == 'ok') {
                         return doSaveView(dbURL, ddocId, viewName, view, true);
                       }
                       modal.finish();
                       spinner.remove();
                     }});
    }

    function saveSucceeded(ddocId, viewName) {
      modal.finish();
      spinner.remove();
      hideDialog(dialog);
      self.rawDDocIdCell.setValue(ddocId);
      self.rawViewNameCell.setValue(viewName);
      self.allDDocsCell.recalculate();
    }
  },
  saveView: function () {
    var self = this;
    var dialog = $('#copy_view_dialog');
    var warning = dialog.find('.warning').hide();

    Cell.compute(function (v) {
      var dbURL = v.need(self.dbURLCell);
      var currentView = v.need(self.currentView);
      var pair = v.need(self.currentDDocAndView);
      return [dbURL, currentView].concat(pair);
    }).getValue(function (args) {
      begin.apply(self, args);
    });

    return;

    function begin(dbURL, currentView, ddoc, viewName) {
      var mapCode = self.mapEditor.getValue();
      var reduceCode = self.reduceEditor.getValue();
      var changed = (currentView.map !== mapCode) || ((currentView.reduce || "") !== reduceCode);

      currentView = _.clone(currentView);
      currentView.map = mapCode;
      if (reduceCode) {
        currentView.reduce = reduceCode;
      } else {
        delete currentView.reduce;
      }
      return ViewsSection.doSaveView(dbURL, ddoc._id, viewName, true, saveCallback, currentView);

      function saveCallback() {
        self.allDDocsCell.recalculate();
      }
    }
  },
  runCurrentView: function () {
    ViewsFilter.closeFilter();
    this.pageNumberCell.setValue("1");
    this.viewResultsURLCell.runView();
  },
  showView: function (plink) {
    return unbuildViewPseudoLink(plink, this.doShowView, this);
  },
  doShowView: function (bucketName, ddocId, viewName) {
    var self = this;
    self.withBucketAndDDoc(bucketName, ddocId, function (ddocURL, ddoc) {
      if (!ddoc) {
        return;
      }
      self.rawDDocIdCell.setValue(ddoc._id);
      self.rawViewNameCell.setValue(viewName);
    });
  },
  startPublish: function (id) {
    var self = this;
    self.withDDoc(id, function (ddocURL, ddoc, dbURL) {
      if (!ddocURL) {
        return;
      }
      genericDialog({header: 'Confirm Publishing',
                     text: 'If there is an existing design document ' +
                       'in production with this name, it will be overwritten. Please confirm.',
                     buttons: {ok: "Confirm", cancel: true},
                     callback: function (e, name, instance) {
                       if (name != 'ok') {
                         instance.close();
                         return;
                       }
                       publish(instance);
                     }});
      return;

      function publish(dialogInstance) {
        var name = self.cutOffDesignPrefix(ddoc._id);
        var newId = "_design/" + name;
        var modal = new ModalAction();
        var spinner = overlayWithSpinner(dialogInstance.dialog);
        self.doSaveAs(dbURL, ddoc, newId, true, function (arg) {
          if (arg != 'ok') BUG();
          spinner.remove();
          modal.finish();
          dialogInstance.close();
          self.allDDocsCell.recalculate();
          self.modeTabs.setValue('production');
        });
      }
    });
  },
  onEnter: function () {
  },
  onLeave: function () {
    this.rawDDocIdCell.setValue(undefined);
    this.pageNumberCell.setValue(undefined);
    this.rawViewNameCell.setValue(undefined);
    ViewsFilter.reset();
  },
  navClick: function () {
    this.onLeave();
    this.onEnter();
  }
};

configureActionHashParam("deleteDDoc", $m(ViewsSection, "startDDocDelete"));
configureActionHashParam("copyDDoc", $m(ViewsSection, "startDDocCopy"));
configureActionHashParam("showView", $m(ViewsSection, "showView"));
configureActionHashParam("removeView", $m(ViewsSection, "startRemoveView"));
configureActionHashParam("publishDDoc", $m(ViewsSection, "startPublish"));
configureActionHashParam("addView", $m(ViewsSection, "startCreateView"));

var ViewsFilter = {
  rawFilterParamsCell: new StringHashFragmentCell("viewsFilter"),
  reset: function () {
    this.rawFilterParamsCell.setValue(undefined);
  },
  init: function () {
    var self = this;

    self.filterParamsCell = Cell.computeEager(function (v) {
      var filterParams = v(self.rawFilterParamsCell) || "";
      filterParams = decodeURIComponent(filterParams);
      return $.deparam(filterParams);
    });

    self.filter = $('#view_results_block .f_popup');

    var selectInstance = self.selectInstance = self.filter.find(".selectBox");
    selectInstance.selectBox();

    $("#view_results_block .exp_filter").toggle(_.bind(self.openFilter, self),
                                                _.bind(self.closeFilter, self));

    $("#view_filter_add").bind('click', function (e) {
      var value = selectInstance.selectBox("value");
      if (!value) {
        return;
      }
      var input = self.filter.find('[name=' + value + ']');
      if (input.attr('type') === 'checkbox') {
        input.prop('checked', false);
      } else {
        input.val("");
      }
      input.closest('tr').show();
      selectInstance.selectBox("destroy");
      // jquery is broken. this is workaround, because $%#$%
      selectInstance.removeData('selectBoxControl').removeData('selectBoxSettings');
      selectInstance.find("option[value="+value+"]").prop("disabled", true);
      selectInstance.selectBox();
    });

    self.filter.delegate('.ic_key', 'click', function () {
      var row = $(this).closest('tr');
      var name = row.find('[name]').attr('name')
      row.hide();
      selectInstance.selectBox("destroy");
      // jquery is broken. this is workaround, because $%#$%
      selectInstance.removeData('selectBoxControl').removeData('selectBoxSettings');
      selectInstance.find("option[value="+name+"]").prop("disabled", false);
      selectInstance.selectBox();
    });
  },
  openFilter: function () {
    var self = this;
    self.filterParamsCell.getValue(function (params) {
      self.filter.closest('.f_wrap').find('.exp_filter').addClass("selected");
      self.filter.addClass("visib");
      self.fillInputs(params);
    });
  },
  closeFilter: function () {
    if (!this.filter.hasClass('visib')) {
      return;
    }
    this.inputs2filterParams();
    this.filter.closest('.f_wrap').find('.exp_filter').removeClass("selected");
    this.filter.removeClass("visib");
  },
  inputs2filterParams: function () {
    var params = this.parseInputs();
    var packedParams = encodeURIComponent($.param(params));
    this.rawFilterParamsCell.setValue(packedParams);
  },
  iterateInputs: function (body) {
    this.filter.find('.key input').each(function () {
      var el = $(this);
      var name = el.attr('name');
      var type = (el.attr('type') === 'checkbox') ? 'bool' : 'json';
      var val = (type === 'bool') ? !!el.prop('checked') : el.val();
      body(name, type, val, el);
    });
  },
  fillInputs: function (params) {
    this.iterateInputs(function (name, type, val, el) {
      var row = el.closest('tr');
      if (params[name] === undefined) {
        row.hide();
        return;
      }
      row.show();
      if (type == 'bool') {
        el.prop('checked', !(params[name] === 'false' || params[name] === false));
      } else {
        el.val(params[name]);
      }
    });
    this.selectInstance.selectBox("destroy");
      // jquery is broken. this is workaround, because $%#$%
    this.selectInstance.removeData('selectBoxControl').removeData('selectBoxSettings');
    this.selectInstance.find("option").each(function () {
      var option = $(this);
      var value = option.attr('value');
      option.prop('disabled', value in params);
    });
    this.selectInstance.selectBox();
  },
  parseInputs: function() {
    var rv = {};
    this.iterateInputs(function (name, type, val, el) {
      var row = el.closest('tr');
      if (row.get(0).style.display === 'none') {
        return;
      }
      rv[name] = val;
    });
    return rv;
  }
};

$(function () {
  ViewsFilter.init();
});
