angular.module('mnSettingsAlerts').controller('mnSettingsAlertsController',
  function($scope, mnHelper, mnSettingsAlertsService, alertsSettings) {
    $scope.state = alertsSettings;
    function getParams() {
      var params = _.clone($scope.state);
      params.alerts = mnHelper.checkboxesToList(params.alerts);
      params.recipients = params.recipients.replace(/\s+/g, ',');
      params.emailUser = params.emailServer.user;
      params.emailPass = params.emailServer.pass;
      params.emailHost = params.emailServer.host;
      params.emailPort = params.emailServer.port;
      params.emailEncrypt = params.emailServer.encrypt;
      delete params.emailServer;
      delete params.knownAlerts;
      return params;
    }
    $scope.testEmail = function() {
      var params = getParams();
      params.subject = 'Test email from Couchbase Server';
      params.body = 'This email was sent to you to test the email alert email server settings.';

      mnHelper.promiseHelper($scope, mnSettingsAlertsService.testMail(params))
        .showSpinner()
        .showGlobalSuccess('Test email was sent successfully!')
        .catchGlobalErrors('An error occurred during sending test email.');
    };
    $scope.submit = function() {
      var params = getParams();
      mnHelper.promiseHelper($scope, mnSettingsAlertsService.saveAlerts(params))
        .showErrorsSensitiveSpinner()
        .prepareErrors(function (resp) {
          resp.data = resp.data.errors;
          return resp;
        })
        .catchErrors()
        .reloadState();
    }
  }).filter('alertsLabel', function (knownAlerts) {
  return function (name) {
    switch (name) {
      case knownAlerts[0]: return 'Node was auto-failed-over';
      case knownAlerts[1]: return 'Maximum number of auto-failed-over nodes was reached';
      case knownAlerts[2]: return 'Node wasn\'t auto-failed-over as other nodes are down at the same time';
      case knownAlerts[3]: return 'Node was not auto-failed-over as there are not enough nodes in the cluster running the same service';
      case knownAlerts[4]: return 'Node\'s IP address has changed unexpectedly';
      case knownAlerts[5]: return 'Disk space used for persistent storage has reached at least 90% of capacity';
      case knownAlerts[6]: return 'Metadata overhead is more than 50%';
      case knownAlerts[7]: return 'Bucket memory on a node is entirely used for metadata';
      case knownAlerts[8]: return 'Writing data to disk for a specific bucket has failed';
    }
  };
});
