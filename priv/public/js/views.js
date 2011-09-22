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
  return encodeURIComponent(_.map([bucketName, ddoc._id, viewName], encodeURIComponent).join("/"));
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
  $.ajax({type: method,
          url: url,
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

future.capiViewGet = function (ajaxOptions, valueTransformer, newValue, futureWrapper) {
  function missingValueProducer(xhr, options) {
    return {rows: [{key: JSON.parse(xhr.responseText)}]};
  }
  function handleError(xhr, xhrStatus, errMsg) {
    var text;
    try {
      text = xhr.responseText;
    } catch (e) {}
    if (text) {
      try {
        text = JSON.parse(text);
      } catch (e) {
        text = undefined;
      }
    }
    if (!text) {
      text = {error: {xhrStatus: xhrStatus, errMsg: errMsg}};
    }
    dataCallback({rows: [{key: text}]});
  }

  var dataCallback;
  if (ajaxOptions.error || ajaxOptions.missingValueProducer || ajaxOptions.missingValue) {
    BUG();
  }
  ajaxOptions = _.clone(ajaxOptions);
  ajaxOptions.error = handleError;
  ajaxOptions.missingValueProducer = missingValueProducer;
  // we're using future wrapper to get reference to dataCallback
  // so that we can call it from error handler
  return future.get(ajaxOptions, valueTransformer, newValue, function (initXHR) {
    return (future || futureWrapper)(function (__dataCallback) {
      dataCallback = __dataCallback;
      initXHR(dataCallback);
    })
  });
}

function isDevModeDoc(ddoc) {
  var devPrefix = "_design/dev_";
  return ddoc._id.substring(0, devPrefix.length) == devPrefix;
}

var codeMirrorOpts = {
  lineNumbers: true,
    matchBrackets: true,
    mode: "javascript",
    theme: 'default'
};

var ViewsSection = {
  PAGE_LIMIT: 10,
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
                                 "#views .tabs.switcher",
                                 "#views .panes > div",
                                 ["development", "production"]);
    self.modeTabs.subscribeValue(function (tab) {
      views[tab == 'development' ? 'addClass' : 'removeClass']('in-development');
      views[tab == 'development' ? 'removeClass' : 'addClass']('in-production');
    });

    self.subsetTabCell = new LinkSwitchCell('dev_subset', {
      firstItemIsDefault: true
    });
    self.subsetTabCell.addItem("subset_dev", "dev");
    self.subsetTabCell.addItem("subset_prod", "prod");
    self.subsetTabCell.finalizeBuilding();

    self.rawViewsBucketCell = new StringHashFragmentCell("viewsBucket");
    self.rawDDocIdCell = new StringHashFragmentCell("viewsDDocId");
    self.rawViewNameCell = new StringHashFragmentCell("viewsViewName");
    self.pageNumberCell = new StringHashFragmentCell("viewPage");
    self.fullSubsetPageNumberCell = new StringHashFragmentCell("fullSubsetViewPage");

    self.couchbaseBucketsListCell = Cell.compute(function (v) {
      return _.select(v.need(DAL.cells.bucketsListCell), function (info) {
        return info.bucketType == 'membase';
      });
    });

    self.viewsBucketCell = Cell.compute(function (v) {
      var selected = v(self.rawViewsBucketCell);
      if (selected) {
        return selected;
      }
      var buckets = v.need(self.couchbaseBucketsListCell);
      var bucketInfo = _.detect(buckets, function (info) {return info.name === "default"}) || buckets[0];
      if (!bucketInfo) {
        return null;
      }
      return bucketInfo.name;
    });
    self.viewsBucketCell.equality = function (a, b) {return a === b;};

    (function () {
      var cell = Cell.compute(function (v) {
        var mode = v.need(DAL.cells.mode);
        if (mode != 'views') {
          return;
        }

        var allBuckets = v.need(self.couchbaseBucketsListCell);
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

    var haveBucketsCell = Cell.compute(
      function (v) {
        return v.need(self.viewsBucketCell) !== null;
      });

    var selectedBucketCell = self.selectedBucketCell = Cell.compute(function (v) {
      if (v.need(DAL.cells.mode) != 'views')
        return;
      return v.need(self.viewsBucketCell);
    }).name("selectedBucket");

    var dbURLCell = self.dbURLCell = Cell.compute(function (v) {
      var base = v.need(DAL.cells.capiBase);
      var bucketName = v.need(selectedBucketCell);

      if (bucketName) {
        return buildURL(base, bucketName) + "/";
      } else {
        return;
      }
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
      var haveBuckets = v.need(haveBucketsCell);

      if (haveBuckets) {
        return _.map(v.need(rawAllDDocsCell).rows, function (r) {return r.doc});
      } else {
        return [];
      }
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

        var ddocs = _.sortBy(v.need(allDDocsCell), function(ddoc) {
          return !isDevModeDoc(ddoc);
        });
        var ddocAndView = v.need(currentDDocAndView);

        var selectedDDocId = ddocAndView.length && ddocAndView[0]._id;
        var selectedViewName = ddocAndView.length && ddocAndView[1];

        var devOptgroupOutput = false;
        var productionOptgroupOutput = false;
        var groups = _.map(ddocs, function (doc) {
          var rv = "";
          var viewNames = _.keys(doc.views || {}).sort();

          if (isDevModeDoc(doc) && !devOptgroupOutput) {
            rv += '<optgroup label="Development Views" class="topgroup">';
            devOptgroupOutput = true;
          } else if (!isDevModeDoc(doc) && !productionOptgroupOutput) {
            rv += '</optgroup><optgroup label="Production Views" class="topgroup">';
            productionOptgroupOutput = true;
          }
          rv += "<optgroup label='" + escapeHTML(doc._id) + "' class='childgroup'>";
          _.each(viewNames, function (name) {
            var maybeSelected = (selectedDDocId === doc._id && selectedViewName === name) ? ' selected' : '';
            rv += "<option value='" + escapeHTML(buildViewPseudoLink(bucketName, doc, name)) + "'" +
              maybeSelected + ">" +
              escapeHTML(name) + "</option>";
          });
          rv += "</optgroup>";
          return rv;
        });
        groups.push('</optgroup>');
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
            _.defer(function () {
              $('#views_view_select').parent().find('.selectBox-label')
                .html(escapeHTML(ddocId).split('/').join('/<strong>') + '</strong>/_view/<strong>' + escapeHTML(viewName) + '</strong>');
              self.modeTabs.setValue(devMode ? 'development' : 'production');
              self.setCurrentView(ddocId, viewName);
            });
          });
        },
        applyWidget: function () {},
        unapplyWidget: function () {},
        buildOptions: function (q, selected, list) {
          _.each(list, function (group) {
            var option = $(group);
            q.append(option);
          });
          $('#views_view_select').selectBox({autoWidth:true})
            .selectBox('options', list.join(''));
          if (selected.length > 0) {
            $('#views_view_select').parent().find('.selectBox-label')
              .html(escapeHTML(selected[0]._id).split('/').join('/<strong>') + '</strong>/_view/<strong>' + escapeHTML(selected[1]) + '</strong>');
          }
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

        originalMap = view.map;
        originalReduce = view.reduce || "";

        // NOTE: this triggers onChange right now so it needs to be last
        self.mapEditor.setValue(view.map);
        self.reduceEditor.setValue(view.reduce || "");
      });

      var unchangedCell = new Cell();

      var onMapReduceChange = function () {
        var nowMap = self.mapEditor.getValue();
        var nowReduce = self.reduceEditor.getValue();
        var unchanged = (originalMap === nowMap && originalReduce === nowReduce);
        unchangedCell.setValue(unchanged);
      }

      self.mapEditor.setOption('onChange', onMapReduceChange);
      self.reduceEditor.setOption('onChange', onMapReduceChange);
      unchangedCell.subscribeValue(function (unchanged) {
        $('#view_run_button').toggleClass('disabled', !unchanged);
      });

    })();

    function enableEditor(editor) {
      editor.setOption('readOnly', false);
      editor.setOption('lineNumbers', true);
      editor.setOption('matchBrackets', true);
      $(editor.getWrapperElement()).removeClass('read_only');
    }

    function disableEditor(editor) {
      editor.setOption('readOnly', 'nocursor');
      editor.setOption('lineNumbers', false);
      editor.setOption('matchBrackets', false);
      $(editor.getWrapperElement())
        .addClass('read_only')
        .closest('.shadow_box').removeClass('editing');
    }

    var editingDevView = Cell.compute(function (v) {
      var ddoc = v.need(currentDDocAndView)[0];
      if (!ddoc) {
        return false;
      }
      return !!ddoc._id.match(/^_design\/dev_/);
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

    function mkIntPageCell(pageNumberCell) {
      return Cell.compute(function (v) {
        var pageVal = v(pageNumberCell);
        var pageNo = parseInt(pageVal, 10);
        if (isNaN(pageNo) || pageNo < 1) {
          pageNo = 1;
        }
        if (pageNo > 10) {
          pageNo = 10;
        }
        return pageNo;
      })
    }

    var intPageCell = mkIntPageCell(self.pageNumberCell);
    var intFullSubsetPageCell = mkIntPageCell(self.fullSubsetPageNumberCell);

    var viewResultsURLCell;
    var defaultSubsetResultsURLCell;
    var fullSubsetResultsURLCell;

    (function () {
      var proposedURLBuilderCell = Cell.compute(function (v) {
        if (!v(self.currentView)) {
          return;
        }
        var dbURL = v.need(self.dbURLCell);
        var ddocAndView = v.need(self.currentDDocAndView);
        if (!ddocAndView[1]) {
          return;
        }
        var filterParams = v.need(ViewsFilter.filterParamsCell);
        return function (pageNo, subset) {
          var initial = {};
          if (subset === "prod") {
            initial.full_set = 'true'
          }
          return buildDocURL(dbURL, ddocAndView[0]._id, "_view", ddocAndView[1], _.extend(initial, filterParams, {
            limit: ViewsSection.PAGE_LIMIT.toString(),
            skip: String((pageNo - 1) * 10)
          }));
        }
      }).name("proposedURLBuilderCell");

      DAL.subscribeWhenSection(Cell.compute(function (v) {
        var subset = v.need(self.subsetTabCell);
        var intPage = subset === 'prod' ? v.need(intFullSubsetPageCell) : v.need(intPageCell);
        return [v(proposedURLBuilderCell), intPage, subset];
      }), "views", function (args) {
        if (!args) {
          return;
        }
        (function (builder, intPage, subset) {
          var html="";
          if (builder) {
            var url = builder(intPage, subset);
            var text = url.substring(url.indexOf('?'));
            html = "<a href='" + escapeHTML(url) + "'>" + escapeHTML(text) + '</a>';
          }
          $('#view_query_string').html(html);
        }).apply(this, args);
      });

      var defaultSubsetAppliedURLBuilderCell = new Cell();
      var fullSubsetAppliedURLBuilderCell = new Cell();
      var lastAppliedURLBuilderCell = new Cell();

      defaultSubsetResultsURLCell = Cell.compute(function (v) {
        var appliedBuilder = v(defaultSubsetAppliedURLBuilderCell);
        var proposedBuilder = v.need(proposedURLBuilderCell);
        if (appliedBuilder !== proposedBuilder) {
          return;
        }
        return appliedBuilder(v.need(intPageCell), "dev");
      });
      fullSubsetResultsURLCell = Cell.compute(function (v) {
        var appliedBuilder = v(fullSubsetAppliedURLBuilderCell);
        var proposedBuilder = v.need(proposedURLBuilderCell);
        if (appliedBuilder !== proposedBuilder) {
          return;
        }
        return appliedBuilder(v.need(intFullSubsetPageCell), "prod");
      });
      self.viewResultsURLCell = viewResultsURLCell = Cell.compute(function (v) {
        if (v.need(self.subsetTabCell) === "prod") {
          return v.need(fullSubsetResultsURLCell);
        }
        return v.need(defaultSubsetResultsURLCell);
      });

      viewResultsURLCell.runView = function () {
        var urlCell = defaultSubsetResultsURLCell;
        var appliedBuilderCell = defaultSubsetAppliedURLBuilderCell;
        if (self.subsetTabCell.value === "prod") {
          urlCell = fullSubsetResultsURLCell;
          appliedBuilderCell = fullSubsetAppliedURLBuilderCell;
        }

        urlCell.setValue(undefined);
        Cell.waitQuiescence(function () {
          proposedURLBuilderCell.getValue(function (value) {
            appliedBuilderCell.setValue(value);
            lastAppliedURLBuilderCell.setValue(value);
            urlCell.recalculate();
          });
        });
      };

      proposedURLBuilderCell.subscribeValue(function (proposed) {
        if (proposed !== lastAppliedURLBuilderCell.value) {
          self.subsetTabCell.setValue("dev");
          self.pageNumberCell.setValue(undefined);
          self.fullSubsetPageNumberCell.setValue(undefined);
          lastAppliedURLBuilderCell.setValue(undefined);
          defaultSubsetAppliedURLBuilderCell.setValue(undefined);
          fullSubsetAppliedURLBuilderCell.setValue(undefined);
        }
      });
    })();

    var defaultSubsetViewResultsCell = Cell.compute(function (v) {
      return future.capiViewGet({url: v.need(defaultSubsetResultsURLCell),
                                 timeout: 3600000});
    }).name("defaultSubsetViewResultsCell")

    var fullSubsetViewResultsCell = Cell.compute(function (v) {
      return future.capiViewGet({url: v.need(fullSubsetResultsURLCell),
                                 timeout: 3600000});
    }).name("fullSubsetViewResultsCell")

    var viewResultsCell = Cell.compute(function (v) {
      // NOTE: we're requiring both subsets values, because otherwise
      // cells would deactivate 'other' results cell as not needed
      // anymore.
      var fullResults = v(fullSubsetViewResultsCell);
      var defaultResults = v(defaultSubsetViewResultsCell);
      return v.need(self.subsetTabCell) === 'prod' ? fullResults : defaultResults;
    }).name("viewResultsCell");

    viewResultsCell.subscribeValue(function (value) {
      if (value) {
        var rows = _.filter(value.rows, function (r) {return ('key' in r)});
        var targ = {rows: rows};
      } else {
        var targ = {rows: {lackOfValue: true}};
      }
      renderTemplate('view_results', targ);
    });

    (function () {
      var prevBtn = $('#view_results_block .arr_prev');
      var nextBtn = $('#view_results_block .arr_next');

      DAL.subscribeWhenSection(Cell.compute(function (v) {
        var intCell = v.need(self.subsetTabCell) === 'prod' ? intFullSubsetPageCell : intPageCell;
        return [v(viewResultsCell), v.need(intCell)];
      }), "views", function (args) {
        if (!args) {
          return;
        }
        (function (viewResults, intPage) {
          if (!viewResults) {
            $('#view_results_block .ic_prev_next').hide();
            return;
          }
          $('#view_results_block .ic_prev_next').show();
          prevBtn.toggleClass('disabled', intPage == 1);
          nextBtn.toggleClass('disabled', (viewResults.rows.length < ViewsSection.PAGE_LIMIT) || intPage == 10);
        }).apply(this, args);
      });

      function pageBtnClicker(btn, body) {
        btn.click(function (ev) {
          ev.preventDefault();
          if (btn.hasClass('disabled')) {
            return;
          }
          var cells = [intPageCell, self.pageNumberCell];
          if (self.subsetTabCell.value === "prod") {
            cells = [intFullSubsetPageCell, self.fullSubsetPageNumberCell];
          }
          cells[0].getValue(function (intPage) {
            body(intPage, cells[1]);
          });
        });
      }

      pageBtnClicker(prevBtn, function (intPage, cell) {
        if (intPage > 1) {
          cell.setValue((intPage-1).toString());
        }
      });

      pageBtnClicker(nextBtn, function (intPage, cell) {
        if (intPage < 10) {
          cell.setValue((intPage+1).toString());
        }
      });
    })();

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


    $('#view_run_button').bind('click', function (e) {
      if ($(this).hasClass('disabled')) {
        return;
      }
      e.preventDefault();
      self.runCurrentView();
    });

    var currentDocument = null;

    var jsonCodeEditor = CodeMirror.fromTextArea($("#sample_doc_editor")[0], {
      lineNumbers: false,
      matchBrackets: false,
      mode: {name: "javascript", json: true},
      theme: 'default',
      readOnly: 'nocursor'
    });
    $(jsonCodeEditor.getWrapperElement()).addClass('read_only');

    function fetchRandomId(fun) {
      self.dbURLCell.getValue(function (dbURL) {
        couchReq('GET', buildURL(dbURL, '_random'), null, function (data) {
          // TODO: handle failed lookup of cookie in a more friendly way (especially on empty buckets)
          $.cookie("randomKey", data.id);
          fun(data.id);
          $('#sample_docs').show();
          $('#no_sample_docs').hide();
        }, function() {
          $('#sample_docs').hide();
          $('#no_sample_docs').show();
        });
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

    function showDoc(id, error) {
      self.dbURLCell.getValue(function (dbURL) {
        couchReq('GET', buildDocURL(dbURL, id), null, function (data) {
          currentDocument = $.extend({}, data);
          var tmp = JSON.stringify(data, null, "\t")
          $("#edit_preview_doc").removeClass("disabled");
          $("#lookup_doc_by_id").val(data._id);
          jsonCodeEditor.setValue(tmp);
        }, error);
      });
    }


    function docError(alertMsg) {
      var dialog = genericDialog({
        buttons: {ok: true},
        header: "Alert",
        textHTML: alertMsg,
        callback: function (e, btn, dialog) {
          dialog.close();
        }
      });
    }

    $('#preview_random_doc').bind('click', function(ev, dontReset) {
      if (typeof dontReset == "undefined") {
        $.cookie("randomKey", "");
      }
      randomId(function(id) {
        showDoc(id, function() {
          $("#edit_preview_doc").addClass("disabled");
          $("#lookup_doc_by_id").val(id);
          jsonCodeEditor.setValue("Invalid key");
        });
      });
    });


    $('#edit_preview_doc').click(function(ev) {
      ev.stopPropagation();
      if ($(this).hasClass("disabled")) {
        return;
      }
      $('#sample_docs').addClass('editing')
          .find('.darker_block').removeClass('closed');
      enableEditor(jsonCodeEditor);
    });


    $("#lookup_doc_by_id_btn").bind('click', function(e) {
      e.stopPropagation();
      var id = $("#lookup_doc_by_id").val();
      console.log(id);
      if (id !== "") {
        $.cookie("randomKey", id);
        showDoc(id, function() {
          docError("You specified an invalid id");
        });
      } else {
        docError("Id cannot be empty");
      }
    });

    $("#lookup_doc_by_id").bind('click', function(e) {
      e.stopPropagation();
    });

    $("#view_results_container").bind('mousedown', function(e) {
      if ($(e.target).is("a.id")) {
        showDoc($(e.target).text(), function() {
          docError("Unknown Error");
        });
        window.scrollTo(0, 0);
      }
    });

    $('#cancel_preview_doc').click(function(ev) {
      showDoc($.cookie('randomKey'));
      disableEditor(jsonCodeEditor);
    });
    $('#save_preview_doc').click(function(ev) {

      ev.stopPropagation();
      var json, doc = jsonCodeEditor.getValue();
      try {
        json = JSON.parse(doc);
      } catch(err) {
        docError("You entered invalid JSON");
        return;
      }
      json._id = currentDocument._id;
      json._rev = currentDocument._rev;

      for (var key in json) {
        if (key[0] === "$") {
          delete json[key];
        }
      }

      self.dbURLCell.getValue(function (dbURL) {
        couchReq('PUT', buildDocURL(dbURL, json._id), json, function () {
          disableEditor(jsonCodeEditor);
          showDoc(json._id);
        }, function() {
          docError("There was an unknown problem saving your document");
        });
      });
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
    return id.replace(/^_design\/(dev_|)/, "");
  },
  startDDocCopy: function (id) {
    this.withDDoc(id, function (ddocURL, ddoc, dbURL) {
      if (!ddocURL)
        return;

      var dialog = $('#copy_designdoc_dialog');
      var form = dialog.find("form");

      (function () {
        var name = ViewsSection.cutOffDesignPrefix(ddoc._id);

        setFormValues(form, {
          "ddoc_name": name
        });
      })();

      showDialog(dialog, {
        eventBindings: [['.save_button', 'click', function (e) {
          e.preventDefault();
          var data = $.deparam(serializeForm(form));
          var toId = "_design/dev_" + data.ddoc_name;
          var spinner = overlayWithSpinner($(dialog));
          var needReload = false;

          function closeDialog() {
            spinner.remove();
            hideDialog(dialog);
            if (needReload) {
              ViewsSection.allDDocsCell.recalculate();
              ViewsSection.modeTabs.setValue('development');
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
        map: "function (doc) {\n  emit(doc._id, null);\n}"
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
      ViewsSection.doSaveView(dbURL, "_design/dev_" + ddocName, viewName, false, function (status) {
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

      var newId = "_design/dev_" + newDDocName;

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
    this.viewResultsURLCell.runView();
  },
  showView: function (plink) {
    return unbuildViewPseudoLink(plink, this.doShowView, this);
  },
  setCurrentView: function (ddocId, viewName) {
    var self = this;
    self.dbURLCell.getValue(function (dbURL) {
      self.rawDDocIdCell.setValue(ddocId);
      self.rawViewNameCell.setValue(viewName);
      ViewsFilter.initFilterFor(buildDocURL(dbURL, ddocId, "_view", viewName));
    });
  },
  doShowView: function (bucketName, ddocId, viewName) {
    var self = this;
    self.withBucketAndDDoc(bucketName, ddocId, function (ddocURL, ddoc) {
      if (!ddoc) {
        return;
      }
      self.setCurrentView(ddoc._id, viewName);
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
        var spinner = overlayWithSpinner(dialogInstance.dialog.parent());
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
  rawFilterParamsCell: (function () {
    var klass = mkClass(StringHashFragmentCell, {
      // NOTE: watchHashParamChange is silently converting empty
      // string to undefined we cannot easily fix this as some code
      // might rely on that. Thus we have to request hash parameter
      // and set 'pure' value
      interpretHashFragment: function () {
        this.setValue(getHashFragmentParam(this.paramName));
      }
    });
    return new klass("viewsFilter");
  })(),
  reset: function () {
    if (this.currentViewURL) {
      this.saveFilterIntoHistory();
      this.currentViewURL = null;
    }
    this.rawFilterParamsCell.setValue(undefined);
  },
  init: function () {
    var self = this;

    self.filterParamsCell = Cell.computeEager(function (v) {
      var filterParams = v(self.rawFilterParamsCell);
      if (filterParams == null) {
        if (v.need(ViewsSection.modeTabs) === 'production') {
          filterParams = "stale=update_after&connection_timeout=60000";
        } else {
          filterParams = "connection_timeout=60000";
        }
      }
      filterParams = decodeURIComponent(filterParams);
      return $.deparam(filterParams);
    });

    self.filter = $('#view_results_block .f_popup');

    var selectInstance = self.selectInstance = $('#view_filters');
    selectInstance.selectBox();
    $('#view_filter_stale').selectBox();

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

    self.filter.delegate('.btn_x', 'click', function () {
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
    var oldFilterParams = this.rawFilterParamsCell.value;
    if (oldFilterParams !== packedParams) {
      this.rawFilterParamsCell.setValue(packedParams);
      ViewsSection.pageNumberCell.setValue(undefined);
      ViewsSection.fullSubsetPageNumberCell.setValue(undefined);
      this.saveFilterIntoHistory();
    }
  },
  iterateInputs: function (body) {
    this.filter.find('.key input, .key select').each(function () {
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
  },
  loadHistory: function () {
    try {
      return JSON.parse(window.localStorage.filterHistory);
    } catch (e) {
      return [];
    }
  },
  saveHistory: function (history) {
    if (!window.localStorage) {
      return;
    }
    window.localStorage.filterHistory = JSON.stringify(history);
  },
  initFilterFor: function (url) {
    var history = this.loadHistory();
    var entry = _.detect(history, function (entry) {
      return (entry[0] === url);
    });
    this.currentViewURL = url;
    if (!entry) {
      this.rawFilterParamsCell.setValue(undefined);
      return;
    }
    this.rawFilterParamsCell.setValue(entry[1]);
    history = [entry].concat(_.without(history, entry));
    this.saveHistory(history);
  },
  MAX_HISTORY_LENGTH: 256,
  saveFilterIntoHistory: function () {
    var history = this.loadHistory();
    var url = this.currentViewURL;
    if (!url) {
      return;
    }
    var history = _.select(history, function (entry) {
      return entry[0] !== url;
    });
    if (history >= this.MAX_HISTORY_LENGTH) {
      history.pop();
    }
    history.unshift([url, this.rawFilterParamsCell.value]);
    this.saveHistory(history);
  }
};

$(function () {
  ViewsFilter.init();
});
