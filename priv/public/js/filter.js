var isDomObject = function (obj) {
  try {
      return obj instanceof HTMLElement;
  } catch(e) {
      return !!obj && !(obj instanceof Object);
  }
}

function createFilterCells(ns) {
  ns.filterParamsCell = Cell.compute(function (v) {
    var filterParams = v(ns.rawFilterParamsCell);
    if (filterParams) {
      filterParams = decodeURIComponent(filterParams);
      return $.deparam(filterParams);
    } else {
      return {};
    }
  });
}

Filter = function Filter(cfg, forTemplate) {
  if (!(this instanceof Filter)) {
    return new Filter(cfg, forTemplate);
  }

  this.cfg = cfg;
  this.forTemplate = forTemplate;
}

Filter.prototype = {
  errors: {
    tagNotExist: 'Tag with follow selector must be exists',
    wrongTagType: 'Tag must be sended as String, Node or jQuery object'
  },
  init: function () {
    var self = this;
    var cfg = self.cfg || {};
    self.forTemplate = self.forTemplate || {};

    if (cfg.container && self.tagValidation(cfg.container)) {
      self.container = $(cfg.container);

      self.tagValidation(self.container);
      delete cfg.container;
    } else {
      self.container = $('<div />').addClass('filter_container');
    }

    var forAllItems = {
      connectionTimeout: true,
      stale: true,
      updateSeq: true,
      startkeyDocid: true,
      startkey: true,
      reduce: true,
      keys: true,
      key: true,
      inclusiveEnd: true,
      includeDocs: true,
      groupLevel: true,
      group: true,
      endkeyDocid: true,
      endkey: true,
      descending: true,
      conflict: true
    }

    var defaultValues = {
      prefix: '',
      template: 'filter',
      hashName: '',
      onClose: function () {}
    }

    var defaultForTemplate = {
      title: 'Filter Results',
      prefix: '',
      items: {}
    }

    self.forTemplate = _.extend(defaultForTemplate, self.forTemplate);
    _.extend(self, _.extend(defaultValues, cfg));

    if (self.forTemplate.items.all) {
      self.forTemplate.items = _.extend(forAllItems, self.forTemplate.items);
    }

    self.rawFilterParamsCell = new StringHashFragmentCell(self.hashName);
    createFilterCells(self);

    renderTemplate(self.template, self.forTemplate, self.container[0]);

    if (self.appendTo) {
      self.appendTo.append(self.container);
    }

    self.filtersCont = $('.filters_container', self.container);
    self.filtersBtn = $('.filters_btn', self.container);
    self.filtersDropDown = $('.filters_dropdown', self.container);
    self.filtersAdd = $('.filters_add', self.container);
    self.filtersUrl = $('.filters_url', self.container);

    _.each([self.filtersAdd, self.filtersCont, self.filtersBtn, self.filtersDropDown], self.tagValidation, self);

    self.filtersBtn.toggle( _.bind(self.openFilter, self), _.bind(self.closeFilter, self));

    self.filtersDropDown.selectBox();
    $('#' + self.prefix + '_filter_stale', self.container).selectBox();

    self.filtersAdd.click(function (e) {
      var value = self.filtersDropDown.selectBox("value");
      if (!value) {
        return;
      }
      var input = $('[name=' + value + ']', self.filtersCont);
      if (input.attr('type') === 'checkbox') {
        input.prop('checked', false);
      } else if (value === 'keys') {
        input.val('[""]');
      } else {
        input.val("");
      }
      input.parent().show();
      self.resetDropDown(value, true);
    });

    self.filtersCont.delegate('.btn_x', 'click', function () {
      var row = $(this).parent();
      var name = row.find('[name]').attr('name')
      row.hide();
      self.resetDropDown(name);
    });

    return self;
  },
  reset: function () {
    if (this.currentURL) {
      this.currentURL = null;
    }
    this.rawFilterParamsCell.setValue(undefined);
  },
  resetDropDown: function (name, isDisabled) {
    this.filtersDropDown.selectBox("destroy");
    // jquery is broken. this is workaround, because $%#$%
    this.filtersDropDown.removeData('selectBoxControl').removeData('selectBoxSettings');
    this.filtersDropDown.find("option[value=" + name + "]").prop("disabled", isDisabled);
    this.filtersDropDown.selectBox();
  },
  tagValidation: function (tag) {
    var self = this;

    if (!tag && !(tag instanceof String || tag instanceof jQuery || isDomObject(tag))) {
      throw new Error(self.errors.wrongTagType);
    }

    if (!tag.length) {
      throw new Error(self.errors.tagNotExist + ' "' + tag.selector + '"');
    }

    return true;
  },
  openFilter: function () {
    var self = this;
    self.filterParamsCell.getValue(function (params) {
      self.filtersCont.addClass("open");
      self.fillInputs(params);
    });
  },
  closeFilter: function () {
    var self = this;
    if (!self.filtersCont.hasClass('open')) {
      return;
    }
    self.filtersCont.removeClass("open");
    self.inputs2filterParams();
  },
  inputs2filterParams: function () {
    var params = this.parseInputs();
    var packedParams = encodeURIComponent($.param(params));
    var oldFilterParams = this.rawFilterParamsCell.value;
    if (oldFilterParams !== packedParams) {
      this.rawFilterParamsCell.setValue(packedParams);
      this.onClose(packedParams);
    }
  },
  iterateInputs: function (body) {
    $('.key input, .key select', this.filtersCont).each(function () {
      var el = $(this);
      var name = el.attr('name');
      var type = (el.attr('type') === 'checkbox') ? 'bool' : 'json';
      var val = (type === 'bool') ? !!el.prop('checked') : el.val();
      body(name, type, val, el);
    });
  },
  fillInputs: function (params) {
    this.iterateInputs(function (name, type, val, el) {
      var row = el.parent();
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
    this.filtersDropDown.selectBox("destroy");
      // jquery is broken. this is workaround, because $%#$%
    this.filtersDropDown.removeData('selectBoxControl').removeData('selectBoxSettings');
    this.filtersDropDown.find("option").each(function () {
      var option = $(this);
      var value = option.attr('value');
      option.prop('disabled', value in params);
    });
    this.filtersDropDown.selectBox();
  },
  parseInputs: function() {
    var rv = {};
    this.iterateInputs(function (name, type, val, el) {
      var row = el.parent();
      if (row.get(0).style.display === 'none') {
        return;
      }
      rv[name] = val;
    });
    return rv;
  }
}