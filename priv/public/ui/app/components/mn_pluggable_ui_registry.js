(function () {
  "use strict";

  angular
    .module('mnPluggableUiRegistry', [])
    .factory('mnPluggableUiRegistry', mnPluggableUiRegistryFactory);

  function mnPluggableUiRegistryFactory() {
    var _configs = [];
    return {
      getConfigs: getConfigs,
      registerConfig: registerConfig
    };

    /**
     * Returns a list of the registered plugabble UI configs.
     * @returns {Array}
     */
    function getConfigs() {
      return _configs;
    }
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
  }
}());
