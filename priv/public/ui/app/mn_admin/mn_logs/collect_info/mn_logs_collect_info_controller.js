(function () {
  "use strict";

  angular
    .module('mnLogs')
    .controller('mnLogsCollectInfoController', mnLogsCollectInfoController);

  function mnLogsCollectInfoController($scope, mnHelper, mnPromiseHelper, mnPoolDefault, mnLogsCollectInfoService, mnPoller, $state, $uibModal) {
    var vm = this;
    vm.mnPoolDefault = mnPoolDefault.latestValue();
    vm.stopCollection = stopCollection;
    vm.submit = submit;

    activate();

    if (vm.mnPoolDefault.value.isROAdminCreds) {
      return;
    }
    vm.collect = {
      nodes: {},
      from: '*'
    };
    if (vm.mnPoolDefault.value.isEnterprise) {
      vm.collect.uploadHost = 's3.amazonaws.com/cb-customers';
    }

    function activate() {
      new mnPoller($scope, mnLogsCollectInfoService.getState)
      .subscribe(function (state) {
        vm.loadingResult = false;
        vm.state = state;
      })
      .cycle();
    }

    function stopCollection() {
      $uibModal.open({
        templateUrl: 'app/mn_admin/mn_logs/collect_info/mn_logs_collect_info_stop_dialog.html'
      }).result.then(function () {
        vm.disabledStopCollect = true;
        mnPromiseHelper(vm, mnLogsCollectInfoService.cancelLogsCollection())
          .getPromise()['finally'](function () {
            vm.disabledStopCollect = false;
          });
      });
    }
    function submit() {
      var collect = _.clone(vm.collect);
      collect.nodes = !collect.from ? mnHelper.checkboxesToList(collect.nodes).join(',') : '*';
      if (!collect.upload) {
        delete collect.uploadHost;
        delete collect.customer;
        delete collect.ticket;
      }
      var promise = mnLogsCollectInfoService.startLogsCollection(collect);
      mnPromiseHelper(vm, promise)
        .showSpinner()
        .catchErrors()
        .onSuccess(function () {
          vm.loadingResult = true;
          $state.go('app.admin.logs.collectInfo.result');
        });
    }
  }
})();
