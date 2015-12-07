(function () {
  "use strict";

  angular.module('mnSettingsAutoCompactionService', [
    'mnFilters'
  ]).factory('mnSettingsAutoCompactionService', mnSettingsAutoCompactionServiceFactory);

  function mnSettingsAutoCompactionServiceFactory($http, mnBytesToMBFilter, mnMBtoBytesFilter) {
    var mnSettingsAutoCompactionService = {
      prepareSettingsForView: prepareSettingsForView,
      prepareSettingsForSaving: prepareSettingsForSaving,
      getAutoCompaction: getAutoCompaction,
      saveAutoCompaction: saveAutoCompaction
    };

    return mnSettingsAutoCompactionService;

    function prepareValuesForView(holder) {
      angular.forEach(['size', 'percentage'], function (fieldName) {
        if (holder[fieldName] === "undefined") {
          holder[fieldName] = "";
        } else {
          holder[fieldName + 'Flag'] = true;
          fieldName === "size" && (holder[fieldName] = mnBytesToMBFilter(holder[fieldName]));
        }
      });
    }
    function prepareSettingsForView(settings) {
      var acSettings = settings.autoCompactionSettings;
      prepareValuesForView(acSettings.databaseFragmentationThreshold);
      prepareValuesForView(acSettings.viewFragmentationThreshold);
      acSettings.allowedTimePeriodFlag = !!acSettings.allowedTimePeriod;
      acSettings.purgeInterval = settings.purgeInterval;
      !acSettings.allowedTimePeriod && (acSettings.allowedTimePeriod = {
        abortOutside: false,
        toMinute: '',
        toHour: '',
        fromMinute: '',
        fromHour: ''
      });
      return acSettings;
    }
    function prepareVluesForSaving(holder) {
      angular.forEach(['size', 'percentage'], function (fieldName) {
        if (!holder[fieldName + 'Flag']) {
          delete holder[fieldName];
        } else {
          fieldName === "size" && (holder[fieldName] = mnMBtoBytesFilter(holder[fieldName]));
        }
      });
    }
    function prepareSettingsForSaving(acSettings) {
      if (!acSettings) {
        return acSettings;
      }

      acSettings = _.clone(acSettings, true);
      if (!acSettings.allowedTimePeriodFlag) {
        delete acSettings.allowedTimePeriod;
      }
      prepareVluesForSaving(acSettings.databaseFragmentationThreshold);
      prepareVluesForSaving(acSettings.viewFragmentationThreshold);
      delete acSettings.databaseFragmentationThreshold.sizeFlag;
      delete acSettings.viewFragmentationThreshold.percentageFlag;
      delete acSettings.viewFragmentationThreshold.sizeFlag;
      delete acSettings.databaseFragmentationThreshold.percentageFlag;
      delete acSettings.allowedTimePeriodFlag;
      return acSettings;
    }
    function getAutoCompaction() {
      return $http.get('/settings/autoCompaction').then(function (resp) {
        return mnSettingsAutoCompactionService.prepareSettingsForView(resp.data);
      });
    }
    function saveAutoCompaction(autoCompactionSettings, params) {
      var params = {};
      return $http({
        method: 'POST',
        url: '/controller/setAutoCompaction',
        params: params || {},
        data: mnSettingsAutoCompactionService.prepareSettingsForSaving(autoCompactionSettings)
      });
    }
  }
})();
