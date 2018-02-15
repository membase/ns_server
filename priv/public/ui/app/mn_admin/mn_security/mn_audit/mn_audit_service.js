(function () {
  "use strict";

  angular.module('mnAuditService', [
    'mnPoolDefault'
  ]).factory('mnAuditService', mnAuditServiceFactory);

  function mnAuditServiceFactory($http, $q, mnPoolDefault) {
    var mnAuditService = {
      getAuditSettings: getAuditSettings,
      saveAuditSettings: saveAuditSettings,
      getAuditDescriptors: getAuditDescriptors,
      getState: getState
    };

    return mnAuditService;

    function getState() {
      var queries = [
        getAuditSettings()
      ];

      if (mnPoolDefault.export.compat.atLeast55 &&
          mnPoolDefault.export.isEnterprise) {
        queries.push(getAuditDescriptors())
      }

      return $q.all(queries).then(unpack);
    }

    function getAuditSettings() {
      return $http({
        method: 'GET',
        url: '/settings/audit'
      }).then(function (resp) {
        return resp.data;
      });
    }
    function getAuditDescriptors() {
      return $http({
        method: 'GET',
        url: '/settings/audit/descriptors'
      }).then(function (resp) {
        return _.clone(resp.data);
      });
    }
    function saveAuditSettings(data, validateOnly) {
      var params = {};
      if (validateOnly) {
        params.just_validate = 1;
      }
      return $http({
        method: 'POST',
        url: '/settings/audit',
        params: params,
        data: pack(data)
      }).then(function (resp) {
        if (resp.data.errors && resp.data.errors.disabledUsers) {
          resp.data.errors.disabledUsers =
            resp.data.errors.disabledUsers.replace(/\/local/gi,"/couchbase");
        }
        return resp;
      });
    }
    function mergeEvets(result, value) {
      return result.concat(value);
    }
    function filterDisabled(result, desc) {
      if (!desc.enabledByUI) {
        result.push(desc.id);
      }
      return result;
    }
    function pack(data) {
      var result = {
        auditdEnabled: data.auditdEnabled
      };
      if (mnPoolDefault.export.compat.atLeast55 && mnPoolDefault.export.isEnterprise) {
        result.disabled = _.reduce(
          _.reduce(data.eventsDescriptors, mergeEvets, []),
          filterDisabled, []
        ).join(',');
        result.disabledUsers = data.disabledUsers.replace(/\/couchbase/gi,"/local");
      }
      if (data.auditdEnabled) {
        result.rotateInterval = data.rotateInterval * formatTimeUnit(data.rotateUnit);
        result.logPath = data.logPath;
        result.rotateSize = data.rotateSize;
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
    function unpack(resp) {
      var data = resp[0];
      var eventsDescriptors = resp[1];

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
      if (mnPoolDefault.export.compat.atLeast55 && mnPoolDefault.export.isEnterprise) {
        var mapDisabledIDs = _.groupBy(data.disabled);
        eventsDescriptors.forEach(function (desc) {
          desc.enabledByUI = !mapDisabledIDs[desc.id];
        });
        data.eventsDescriptors = _.groupBy(eventsDescriptors, "module");
        data.disabledUsers = data.disabledUsers.map(function (user) {
          return user.name + "/" + (user.domain === "local" ? "couchbase" : user.domain);
        }).join(',');
      }
      data.logPath = data.logPath || "";
      return data;
    }
  }
})();
