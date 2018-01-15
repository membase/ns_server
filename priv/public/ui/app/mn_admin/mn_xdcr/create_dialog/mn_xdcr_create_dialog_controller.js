(function () {
  "use strict";

  angular
    .module('mnXDCR')
    .controller('mnXDCRCreateDialogController', mnXDCRCreateDialogController);

  function mnXDCRCreateDialogController($scope, $uibModalInstance, $timeout, $window, mnPromiseHelper, mnPoolDefault, mnPools, mnXDCRService, replicationSettings, mnAlertsService) {
    var vm = this;
    var codemirrorInstance;
    var codemirrorMarkers = [];

    vm.editorOptions = {
      lineNumbers: true,
      lineWrapping: true,
      viewportMargin: Infinity,
      mode: null,
      onLoad: function (cm) {
        codemirrorInstance = cm;

        if (vm.mnPoolDefault.value.isEnterprise) {
          var initialTestKeysArr = JSON.parse($window.localStorage.getItem('mn_xdcr_testKeys')) || [];

          vm.testKey = initialTestKeysArr[0] || "";
          vm.filterExpression = $window.localStorage.getItem('mn_xdcr_regex') || "";

          cm.setValue(vm.testKey);
          handleValidateRegex(cm, vm.filterExpression, vm.testKey);

          cm.on('blur', function() {
            var value = cm.getValue().replace(/\r?\n|\r/g, "");
            cm.setValue(value);
            vm.testKey = value;
            $timeout(function () {
              $window.localStorage.setItem('mn_xdcr_testKeys', JSON.stringify([vm.testKey]));
              handleValidateRegex(cm, vm.filterExpression, vm.testKey);
            });
          });
        }
      }
    };

    vm.replication = replicationSettings.data;
    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.mnPools = mnPools.export;
    delete vm.replication.socketOptions;
    vm.replication.replicationType = "continuous";
    vm.replication.type = "xmem";
    vm.createReplication = createReplication;
    vm.onExpressionUpdate = onExpressionUpdate;


    function onExpressionUpdate() {
      $window.localStorage.setItem('mn_xdcr_regex', vm.filterExpression);
      handleValidateRegex(codemirrorInstance, vm.filterExpression, vm.testKey);
    }

    function handleValidateRegex(cm, regex, testKey) {
      if (!testKey || !regex) {
        return;
      }
      return mnPromiseHelper(vm, mnXDCRService.validateRegex(regex, testKey))
        .showSpinner("filterExpressionSpinner")
        .catchErrors("filterExpressionError")
        .onSuccess(function (result) {
          var matches = result.data[codemirrorInstance.getValue()];
          vm.isSucceeded = !!matches.length;

          codemirrorMarkers.forEach(function (marker) {
            marker.clear();
          });

          codemirrorMarkers = [];

          matches.forEach(function (match) {
            codemirrorMarkers.push(
              codemirrorInstance.markText(
                {line: 0, ch: match.startIndex},
                {line: 0, ch: match.endIndex},
                {className: "dynamic-hightlight"}));
          });
        });
    }

    function createReplication() {
      var replication = mnXDCRService.removeExcessSettings(vm.replication);
      if (vm.mnPoolDefault.value.isEnterprise && vm.replication.enableAdvancedFiltering) {
        replication.filterExpression = vm.filterExpression;
      }
      var promise = mnXDCRService.postRelication(replication);
      mnPromiseHelper(vm, promise, $uibModalInstance)
        .showGlobalSpinner()
        .catchErrors(function (error) {
          vm.errors = angular.isString(error) ? {_: error} : error;
        })
        .closeOnSuccess()
        .broadcast("reloadTasksPoller")
        .onSuccess(function (resp) {
          var hasWarnings = !!(resp.data.warnings && resp.data.warnings.length);
          mnAlertsService.formatAndSetAlerts(
            hasWarnings ? resp.data.warnings : "Replication created successfully!",
            hasWarnings ? 'warning': "success",
            hasWarnings ? 0 : 2500);
        });
    };
  }
})();
