var MultiDrawersWidget = mkClass({
  mandatoryOptions: "hashFragmentParam template elementsKey drawerCellName idPrefix".split(" "),
  initialize: function (options) {
    options = this.options = _.extend({
      placeholderCSS: '.settings-placeholder',
      placeholderContainerChildCSS: 'td',
      uriExtractor: function (e) {return e.uri;}
    }, options);

    var missingOptions = _.reject(this.mandatoryOptions, function (n) {
      return (n in options);
    });

    if (missingOptions.length)
      throw new Error("Missing mandatory option(s): " + missingOptions.join(','));

    this.openedNames = new StringSetHashFragmentCell(options.hashFragmentParam);

    if (options.actionLink) {
      configureActionHashParam(options.actionLink, $m(this, 'onActionLinkClick'));
    }

    this.knownKeys = {};

    this.subscriptions = [];
    this.reDrawElements = $m(this, 'reDrawElements');
    this.hookRedrawToCell(this.openedNames);
  },
  hookRedrawToCell: function (cell) {
    cell.subscribe(this.reDrawElements);
  },
  onActionLinkClick: function (uri, isMiddleClick) {
    this.options.actionLinkCallback(uri);
    if (isMiddleClick) {
      this.openElement(uri);
    } else
      this.toggleElement(uri);
  },
  valuesTransformer: function (elements) {
    var self = this;
    var idPrefix = self.options.idPrefix;
    var key = self.options.elementsKey;
    var drawerCellName = self.options.drawerCellName;

    var oldElementsByName = self.elementsByName || {};

    self.elementsByName = {};

    _.each(elements, function (e) {
      e[idPrefix] = _.uniqueId(idPrefix);

      var cell = self.knownKeys[e[key]];

      if (!cell) {
        var uriCell = new Cell(function (openedNames) {
          if (!_.include(openedNames, e[key]))
            return undefined;
          return self.options.uriExtractor(e);
        }, {openedNames: self.openedNames});

        cell = new Cell(function (uri) {
          return future.get({url: uri});
        }, {uri: uriCell});

        self.knownKeys[e[key]] = cell;
      } else {
        cell.keepValueDuringAsync = true;
        cell.invalidate();
      }

      e[drawerCellName] = cell;

      var oldE = oldElementsByName[e[key]];
      var oldCell = oldE && oldE[drawerCellName];

      self.elementsByName[e[key]] = e;
    });
    return elements;
  },
  reDrawElements: function () {
    var self = this;

    var subscriptions = self.subscriptions;
    _.each(subscriptions, function (s) {
      s.cancel();
    });
    subscriptions.length = 0;

    $(self.options.placeholderCSS).hide();

    var elementsByName = self.elementsByName;
    if (!elementsByName)
      return;

    _.each(self.openedNames.value, function (name) {
      var element = elementsByName[name];
      if (!element) {
        console.log("element: ", name, "not found");
        return;
      }

      var parentNode = $i(element[self.options.idPrefix]);
      if (!parentNode) {
        console.log("should not happen");
        return;
      }

      var cell = element[self.options.drawerCellName];

      var q = $(parentNode);

      var container;
      var childCSS = self.options.placeholderContainerChildCSS;
      if (childCSS)
        container = q.find(childCSS)[0];
      else
        container = q[0];

      if (!container) {
        throw new Error("MultiDrawersWidget: bad markup!");
      }

      var s = renderCellTemplate(element[self.options.drawerCellName], [container, self.options.template],
                                 function (value) {
                                   if (!self.options.valueTransformer)
                                     return value;
                                   return self.options.valueTransformer(element, value);
                                 });
      subscriptions.push(s);

      q.show();
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
