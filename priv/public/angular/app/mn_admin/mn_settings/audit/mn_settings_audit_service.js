angular.module('mnSettingsAuditService').factory('mnSettingsAuditService',
  function (mnHttp) {
    var mnSettingsAuditService = {};

    mnSettingsAuditService.getAuditSettings = function () {
      return mnHttp({
        method: 'GET',
        url: '/settings/audit'
      }).then(function(resp) {
        return unpack(resp.data);
      });
    };

    mnSettingsAuditService.saveAuditSettings = function (data, validateOnly) {
      var params = {};
      if (validateOnly) {
        params.just_validate = 1;
      }
      return mnHttp({
        method: 'POST',
        url: '/settings/audit',
        params: params,
        data: pack(data)
      });
    };

    function pack(data) {
      var result = {
        auditdEnabled: data.auditdEnabled
      };
      if (data.auditdEnabled) {
        result.rotateInterval = data.rotateInterval * formatTimeUnit(data.rotateUnit);
        result.logPath = data.logPath;
      }
      return result;
    }

    function formatTimeUnit(unit) {
      switch (unit) {
        case 'minutes': return 60;
        case 'hours': return 3600;
        case 'days': return 86400;
      }
    }

    function unpack(data) {
      if (data.rotateInterval % 86400 == 0) {
        data.rotateInterval /= 86400;
        data.rotateUnit = 'days';
      } else if (data.rotateInterval % 3600 == 0) {
        data.rotateInterval /= 3600;
        data.rotateUnit = 'hours';
      } else {
        data.rotateInterval /= 60;
        data.rotateUnit = 'minutes';
      }
      data.logPath = data.logPath || "";
      return data;
    }

    return mnSettingsAuditService;
});