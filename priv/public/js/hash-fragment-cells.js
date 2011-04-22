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
function ensureElementId(jq) {
  jq.each(function () {
    if (this.id)
      return;
    this.id = _.uniqueId('gen');
  });
  return jq;
}

// this cell type supports only string values and synchronizes
// window.location hash fragment value and cell value
var StringHashFragmentCell = mkClass(Cell, {
  initialize: function ($super, paramName) {
    $super();
    this.paramName = paramName;
    watchHashParamChange(this.paramName, $m(this, 'interpretHashFragment'));
    this.subscribeAny($m(this, 'updateHashFragment'));
  },
  interpretHashFragment: function (value) {
    this.setValue(value);
  },
  updateHashFragment: function () {
    setHashFragmentParam(this.paramName, this.value);
  }
});

// this cell synchronizes set of values (not necessarily strings) and
// set of string values of window.location hash fragment
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

var BaseClickSwitchCell = mkClass(HashFragmentCell, {
  initialize: function ($super, paramName, options) {
    options = _.extend({
      selectedClass: 'selected',
      linkSelector: '*',
      eventSpec: 'click',
      bindMethod: 'live'
    }, options);

    $super(paramName, options);

    this.subscribeAny($m(this, 'updateSelected'));

    var self = this;
    $(self.options.linkSelector)[self.options.bindMethod](self.options.eventSpec, function (event) {
      self.eventHandler(this, event);
    })
  },
  updateSelected: function () {
    var value = this.value;
    if (value == undefined) {
      return;
    }

    var index = _.indexOf(_(this.items).pluck('value'), value);
    if (index < 0) {
      throw new Error('invalid value!');
    }

    var getSelector = this.getSelector;
    var selectors = _.map(this.idToItems,
      function(value, key) {
        return getSelector(key);
      }).join(',');
    $(selectors).removeClass(this.options.selectedClass);

    var id = this.items[index].id;
    $(getSelector(id)).addClass(this.options.selectedClass);
  },
  eventHandler: function (element, event) {
    var id = this.extractElementID(element);
    var item = this.idToItems[id];
    if (!item)
      return;

    this.pushState(id);
    event.preventDefault();
  }
});

// this cell type associates a set of HTML links with a set of values
// (any type) and persists selected value in window.location hash
// fragment
var LinkSwitchCell = mkClass(BaseClickSwitchCell, {
  getSelector: function (id) {
    return '#' + id;
  },
  extractElementID: function (element) {
    return element.id;
  },
  addLink: function (link, value, isDefault) {
    if (link.size() == 0)
      throw new Error('missing link for selector: ' + link.selector);
    var id = ensureElementId(link).attr('id');
    this.addItem(id, value, isDefault);
    return this;
  }
});

// This cell type associates a set of CSS classes with a set of
// values and persists selected value in window.location hash
// fragment. Clicking on any element with on of configured classes
// switches this cell to value associated with that class.
//
// All CSS classes in set must have prefix paramName
var LinkClassSwitchCell = mkClass(BaseClickSwitchCell, {
  getSelector: function (id) {
    return '.' + id;
  },
  extractElementID: function (element) {
    var classNames = element.className.split(' ');
    for (var i = classNames.length-1; i >= 0; i--) {
      var v = classNames[i];
      if (this.idToItems[v])
        return v;
    }
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
  },
  updateSelected: function () {
    this.api.click(Number(this.selectedId));
  }
});


var StringSetHashFragmentCell = mkClass(StringHashFragmentCell, {
  initialize: function ($super, paramName) {
    $super.apply(null, _.rest(arguments));
    // TODO: setValue([]) may trigger interesting cells bug with setValue
    // being called from cell watcher. That has side effect of wiping
    // slaves list
    this.value = [];
  },
  interpretHashFragment: function (value) {
    if (value == null || value == "")
      value = [];
    else
      value = value.split(",");

    this.setValue(value);
  },
  updateHashFragment: function () {
    var value = this.value;
    if (value == null || value.length == 0) {
      value = null;
    } else
      value = value.concat([]).sort().join(',');
    setHashFragmentParam(this.paramName, value);
  },
  addValue: function (value) {
    return this.modifyValue(function (set) {
      return _.uniq(set.concat([value]))
    });
  },
  removeValue: function (value) {
    return this.modifyValue(function (set) {
      return _.without(set, value);
    });
  },
  reset: function () {
    this.setValue([]);
  }
});
