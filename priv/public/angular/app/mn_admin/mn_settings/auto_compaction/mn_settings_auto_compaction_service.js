angular.module('mnSettingsAutoCompactionService').factory('mnSettingsAutoCompactionService',
  function (mnHttp, mnBytesToMBFilter, mnMBtoBytesFilter) {
    var mnSettingsAutoCompactionService = {};

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

    mnSettingsAutoCompactionService.prepareSettingsForView = function (settings) {
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
    };

    function prepareVluesForSaving(holder) {
      angular.forEach(['size', 'percentage'], function (fieldName) {
        if (!holder[fieldName + 'Flag']) {
          delete holder[fieldName];
        } else {
          fieldName === "size" && (holder[fieldName] = mnMBtoBytesFilter(holder[fieldName]));
        }
      });
    }

    mnSettingsAutoCompactionService.prepareSettingsForSaving = function (acSettings) {
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
    };

    mnSettingsAutoCompactionService.getAutoCompaction = function () {
      return mnHttp.get('/settings/autoCompaction').then(function (resp) {
        return mnSettingsAutoCompactionService.prepareSettingsForView(resp.data);
      });
    };
    mnSettingsAutoCompactionService.saveAutoCompaction = function (autoCompactionSettings, params) {
      var params = {};
      return mnHttp({
        method: 'POST',
        url: '/controller/setAutoCompaction',
        params: params || {},
        data: mnSettingsAutoCompactionService.prepareSettingsForSaving(autoCompactionSettings)
      });
    };

    return mnSettingsAutoCompactionService;
});