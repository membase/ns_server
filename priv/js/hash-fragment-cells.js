function ensureElementId(jq) {
  jq.each(function () {
    if (this.id)
      return;
    this.id = _.uniqueId('gen');
  });
  return jq;
}

var HashFragmentCell = mkClass(Cell, {
  initialize: function ($super, paramName, options) {
    $super();

    this.paramName = paramName;
    this.options = _.extend({
      firstValueIsDefault: false
    }, options || {});

    this.idToItems = {};
    this.items = [];
    this.defaultId = undefined;
    this.selectedId = undefined;
  },
  interpretState: function (id) {
    var item = this.idToItems[id];
    if (!item)
      return;

    this.setValue(item.value);
  },
  beforeChangeHook: function (value) {
    if (value === undefined) {
      setHashFragmentParam(this.paramName, undefined);

      this.selectedId = undefined;
      return value;
    }

    var pickedItem = _.detect(this.items, function (item) {
      return item.value == value;
    });
    if (!pickedItem)
      throw new Error("Aiiyee. Unknown value: " + value);

    this.selectedId = pickedItem.id;
    this.pushState(this.selectedId);

    return pickedItem.value;
  },
  // setValue: function (value) {
  //   var _super = $m(this, 'setValue', Cell);
  //   console.log('calling setValue: ', value, getBacktrace());
  //   return _super(value);
  // },
  pushState: function (id) {
    id = String(id);
    var currentState = getHashFragmentParam(this.paramName);
    if (currentState == id || (currentState === undefined && id == this.defaultId))
      return;
    setHashFragmentParam(this.paramName, id);
  },
  addItem: function (id, value, isDefault) {
    var item = {id: id, value: value, index: this.items.length};
    this.items.push(item);
    if (isDefault || (item.index == 0 && this.options.firstItemIsDefault))
      this.defaultId = id;
    this.idToItems[id] = item;
    return this;
  },
  finalizeBuilding: function () {
    watchHashParamChange(this.paramName, this.defaultId, $m(this, 'interpretState'));
    this.interpretState(getHashFragmentParam(this.paramName));
    return this;
  }
});

var LinkSwitchCell = mkClass(HashFragmentCell, {
  initialize: function ($super, paramName, options) {
    options = _.extend({
      selectedClass: 'selected',
      linkSelector: '*',
      eventSpec: 'click'
    }, options);

    $super(paramName, options);

    this.subscribeAny($m(this, 'updateSelected'));

    var self = this;
    $(self.options.linkSelector).live(self.options.eventSpec, function (event) {
      self.eventHandler(this, event);
    })
  },
  updateSelected: function () {
    $(_(this.idToItems).chain().keys().map($i).value()).removeClass(this.options.selectedClass);

    var value = this.value;
    if (value == undefined)
      return;

    var index = _.indexOf(_(this.items).pluck('value'), value);
    if (index < 0)
      throw new Error('invalid value!');

    var id = this.items[index].id;
    $($i(id)).addClass(this.options.selectedClass);
  },
  eventHandler: function (element, event) {
    var id = element.id;
    var item = this.idToItems[id];
    if (!item)
      return;

    this.pushState(id);
    event.preventDefault();
  },
  addLink: function (link, value, isDefault) {
    if (link.size() == 0)
      throw new Error('missing link for selector: ' + link.selector);
    var id = ensureElementId(link).attr('id');
    this.addItem(id, value, isDefault);
    return this;
  }
});

var TabsCell = mkClass(HashFragmentCell, {
  initialize: function ($super, paramName, tabsSelector, panesSelector, values, options) {
    var self = this;
    $super(paramName, $.extend({firstItemIsDefault: true},
                               options || {}));

    self.tabsSelector = tabsSelector;
    self.panesSelector = panesSelector;
    var tabsOptions = $.extend({},
                               options || {},
                               {api: true});
    self.api = $(tabsSelector).tabs(panesSelector, tabsOptions);

    self.api.onBeforeClick($m(this, 'onTabClick'));
    self.subscribeAny($m(this, 'updateSelected'));

    _.each(values, function (val, index) {
      self.addItem(index, val);
    });
    self.finalizeBuilding();
  },
  onTabClick: function (event, index) {
    var item = this.idToItems[index];
    if (!item)
      return;
    this.pushState(index);

    if (event.originalEvent)
      event.originalEvent.preventDefault();
  },
  updateSelected: function () {
    this.api.click(Number(this.selectedId));
  }
});
