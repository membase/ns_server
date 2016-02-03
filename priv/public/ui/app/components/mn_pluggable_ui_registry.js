(function () {
  "use strict";

  angular
    .module('mnPluggableUiRegistry', [])
    .provider('mnPluggableUiRegistry', mnPluggableUiRegistryProvider)
    .factory('mnPluggableTabUtil', mnPluggableTabUtil)
    .directive('mnPluggableUiTabs', mnPluggableUiTabs);

  function mnPluggableTabUtil() {
    var defaultTemplate = "<li><a ui-sref=\"{{ ::pluggableUiConfig.state }}\" ui-sref-active=\"selected\">{{ ::pluggableUiConfig.name }}</a></li>";
    var tabTemplates = {
      adminTab:    "<li class=\"line\" ui-sref-active=\"currentNav\"><a ui-sref=\"{{ ::pluggableUiConfig.state}}\">{{ ::pluggableUiConfig.name }}</a></li>",
      indexesTab:  "<li><a ui-sref=\"{{::pluggableUiConfig.state }}\" ng-class=\"selected\">{{ ::pluggableUiConfig.name }}</a></li>"
    };

    return {
      getTabTemplate: getTabTemplate
    };

    function getTabTemplate(tabBarName) {
      return tabTemplates[tabBarName] || defaultTemplate;
    }
  }

  function mnPluggableUiTabs(mnPluggableUiRegistry, mnPluggableTabUtil, $compile) {

    return {
      link: link
    };

    function link($scope, $element, $attrs) {
      var pluggableUiConfigs = mnPluggableUiRegistry.getConfigsByTabBarName($attrs.mnTabBarName);
      if (!pluggableUiConfigs.length) {
        return;
      }
      angular.forEach(pluggableUiConfigs, function (config) {
        $scope.pluggableUiConfig = config;
        if (config.after) {
          var targetTab = $element[0].querySelector("[mn-tab='" + config.after + "']");
          if (!targetTab) {
            throw new Error("There is no tab with mn-tab=" + config.after + " in " + $attrs.mnTabBarName);
          }
          var compiled = $compile(mnPluggableTabUtil.getTabTemplate($attrs.mnTabBarName))($scope);
          angular.element(targetTab).after(compiled);
        } else {
          var compiled = $compile(mnPluggableTabUtil.getTabTemplate($attrs.mnTabBarName))($scope);
          $element.append(compiled);
        }
      });
    }
  }

  function mnPluggableUiRegistryProvider() {
    var _configs = [];

    this.registerConfig = registerConfig;
    this.$get = mnPluggableUiRegistryFactory;

    /**
     * Registers a UI component config with the pluggable UI registry service so that the
     * component can be displayed in the UI.
     *
     * The pluggable UI framework understands the following attributes of the config:
     * 1) name - the name of the UI component to be registered. This is used appropriately
     *    in the UI when the component is displayed. For instance, if the component is
     *    rendered in a tab, the value of name will be used in the tab name.
     * 2) state - the name of the ui.router state for this component. When the time comes to
     *    render the component this is what is used to find it.
     * 3) plugIn - where the component plugs-in to the UI. Currently only 2 values are supported.
     *    If a value other than these 2 is specified, the component won't be displayed.
     *    a) 'adminTab' - to be used in the case that the pluggable component wishes to plug-in to
     *        global nav bar
     *    b) 'settingsTab' - to be used in the case that the pluggable component wishes to
     *        plug in to the the settings tab bar
     *
     * Any attributes beyond these are not understood and are ignored.
     * @param config
     */
    function registerConfig(config) {
      _configs.push(config);
    }

    function mnPluggableUiRegistryFactory() {

      return {
        getConfigs: getConfigs,
        getConfigsByTabBarName: getConfigsByTabBarName
      };

      /**
       * Returns a list of the registered plugabble UI configs.
       * @returns {Array}
       */
      function getConfigs() {
        return _configs;
      }
      function getConfigsByTabBarName(tabBarName) {
        return _.filter(_configs, {plugIn: tabBarName});
      }
    }
  }
}());
