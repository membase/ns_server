angular.module('mnSettingsAlertsService', [
  'mnHttp'
]).factory('mnSettingsAlertsService',
  function (mnHttp, knownAlerts) {
    var mnSettingsAlertsService = {};

    mnSettingsAlertsService.testMail = function (params) {
      params = _.clone(params);
      params.alerts = params.alerts.join(',');
      return mnHttp.post('/settings/alerts/testEmail', params);
    };

    mnSettingsAlertsService.saveAlerts = function (params) {
      params = _.clone(params);
      params.alerts = params.alerts.join(',');
      return mnHttp.post('/settings/alerts', params);
    };

    mnSettingsAlertsService.getAlerts = function () {
      return mnHttp.get('/settings/alerts').then(function (resp) {
        var val = _.clone(resp.data);
        val.recipients = val.recipients.join('\n');
        val.knownAlerts = _.clone(knownAlerts);
        // {auto_failover_node: true, auto_failover_maximum_reached: true ...}
        val.alerts = _.zipObject(val.alerts, _.fill(new Array(val.knownAlerts.length), true, 0, val.knownAlerts.length));

        return val;
      });
    };

    return mnSettingsAlertsService;
});