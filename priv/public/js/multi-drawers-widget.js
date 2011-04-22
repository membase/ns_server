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
var KeyedMap = mkClass({
  initialize: function (itemKeyFunction) {
    if (!(itemKeyFunction instanceof Function)) {
      var keyAttr = itemKeyFunction;
      itemKeyFunction = function (item) {return item[keyAttr]};
    }
    this.keyOf = itemKeyFunction;
    this.map = {};
  },
  put: function (item, target) {
    this.map[this.keyOf(item)] = target;
  },
  clear: function () {
    this.map = {}
  },
  remove: function (item) {
    if (item == null)
      return;
    var key = this.keyOf(item);
    var rv = this.map[key];
    delete this.map[key];
    return rv;
  },
  get: function (item) {
    if (item == null)
      return;
    return this.map[this.keyOf(item)];
  }
});

// applies function to all items and forms KeyedMap with items ->
// values association. Takes care of reusing old values when recomputing
Cell.mapAllKeys = function (itemsCell, itemKeyFunction, valueFunction) {
  return Cell.compute(function (v) {
    var items = v.need(itemsCell);
    var newMap = new KeyedMap(itemKeyFunction);
    var oldMap = this.self.value || newMap;

    _.each(items, function (item) {
      var value = oldMap.get(item) || valueFunction(item);
      newMap.put(item, value);
    });

    return newMap;
  });
}

// TODO
Cell.computeListDetails = function (itemsCell, detailsAttr, detailsFunction) {
  return Cell.compute(function (v) {
    return _.map(v.need(itemsCell), function (item) {
      item = _.clone(item);
      item[detailsAttr] = detailsFunction(item);
      return item;
    });
  });
}

var MultiDrawersWidget = mkClass({
  mandatoryOptions: "hashFragmentParam template elementKey listCell".split(" "),
  initialize: function (options) {
    options = this.options = _.extend({
      placeholderCSS: '.settings-placeholder'
    }, options);

    var missingOptions = _.reject(this.mandatoryOptions, function (n) {
      return (n in options);
    });

    if (missingOptions.length)
      throw new Error("Missing mandatory option(s): " + missingOptions.join(','));

    if (options.actionLink) {
      configureActionHashParam(options.actionLink, $m(this, 'onActionLinkClick'));
    }

    this.knownKeys = {};

    this.elementKey = this.options.elementKey;
    if (!(this.elementKey instanceof Function)) {
      this.elementKey = (function (itemAttr) {
        return function (item) {return item[itemAttr]};
      })(this.elementKey);
    }

    this.subscriptions = [];

    var openedNamesCell = this.openedNames = new StringSetHashFragmentCell(options.hashFragmentParam);

    var detailsCellProducer = (function (self) {
      return function (item, key) {
        console.log("producing details cell for key: ", key, ", item: ", item);
        var detailsCell = Cell.compute(function (v) {
          var url;

          if (self.options.uriExtractor)
            url = self.options.uriExtractor(item);
          else
            url = key;

          return future.get({url: url});
        });

        var interested = Cell.compute(function (v) {
          if (v.need(options.listCell.ensureMetaCell()).stale)
            return false;
          return _.include(v(openedNamesCell) || [], key);
        });

        var rv = Cell.compute(function (v) {
          if (!v(interested))
            return;
          return v(detailsCell);
        });

        rv.interested = interested;
        detailsCell.keepValueDuringAsync = true;
        rv.invalidate = $m(detailsCell, 'invalidate');

        return rv;
      }
    })(this);

    this.detailsMap = Cell.compute(function (v) {
      var map = new KeyedMap(options.elementKey);
      var oldMap = this.self.value || map;
      _.each(v.need(options.listCell), function (item) {
        var value = oldMap.get(item);
        if (value) {
          value.invalidate();
        } else {
          value = detailsCellProducer(item, map.keyOf(item));
        }
        map.put(item, value);
      });
      return map;
    });
  },
  onActionLinkClick: function (uri, isMiddleClick) {
    this.options.actionLinkCallback(uri);
    if (isMiddleClick) {
      this.openElement(uri);
    } else
      this.toggleElement(uri);
  },
  prepareDrawing: function () {
    var subscriptions = this.subscriptions;
    _.each(subscriptions, function (s) {
      s.cancel();
    });
    subscriptions.length = 0;

    $(this.options.placeholderCSS).hide();
  },
  subscribeDetailsRendering: function (parentNode, item) {
    var self = this;
    var options = self.options;
    var subscriptions = self.subscriptions;

    var q = $(parentNode);

    var container = q[0];
    if (!container) {
      throw new Error("MultiDrawersWidget: bad markup!");
    }

    var detailsCell;
    var valueSubscription = self.detailsMap.subscribeValue(function (detailsMap) {
      if (detailsCell)
        return;
      if (!detailsMap)
        return;
      detailsCell = detailsMap.get(item);
      if (!detailsCell)
        return;

      // we subscribe to detailsCell only once, which is first time we
      // get it

      var valueTransformer;
      if (self.options.valueTransformer) {
        valueTransformer = (function (transformer) {
          return function (value) {
            return transformer(item, value);
          }
        })(self.options.valueTransformer);
      }

      var renderer = mkCellRenderer([container, self.options.template], {
        hideIf: function (cell) {
          return !cell.interested.value;
        },
        valueTransformer: valueTransformer
      }, detailsCell);

      // this makes sure we render when any of interesting cells change
      var s = Cell.compute(function (v) {
        return [v(detailsCell), v(detailsCell.interested)];
      }).subscribeValue(function (array) {
        renderer();
      });

      subscriptions.push(s);
    });

    subscriptions.push(valueSubscription);
  },
  renderItemDetails: function (item) {
    var self = this;
    return ViewHelpers.thisElement(function (element) {
      self.subscribeDetailsRendering(element, item);
    });
  },
  toggleElement: function (name) {
    if (_.include(this.openedNames.value, name)) {
      this.closeElement(name);
    } else {
      this.openElement(name);
    }
  },
  openElement: function (name) {
    this.openedNames.addValue(name);
  },
  closeElement: function (name) {
    this.openedNames.removeValue(name);
  },
  reset: function () {
    this.openedNames.reset();
  }
});
