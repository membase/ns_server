angular.module('mnLogs').controller('mnLogsCollectInfoController',
  function ($scope, mnHelper, mnPromiseHelper, mnLogsCollectInfoService, mnPoll, state, $state, $modal) {
    function applyState(state) {
      $scope.loadingResult = false;
      $scope.state = state;
    }
    $scope.stopCollection = function () {
      $modal.open({
        templateUrl: '/angular/app/mn_admin/mn_logs/collect_info/mn_logs_collect_info_stop_dialog.html'
      }).result.then(function () {
        $scope.disabledStopCollect = true;
        mnLogsCollectInfoService.cancelLogsCollection()['finally'](function () {
          $scope.disabledStopCollect = false;
        })
      });
    };
    $scope.collect = {
      nodes: {},
      from: '*'
      // uploadHost: 's3.amazonaws.com/cb-customers'
    };
    $scope.submit = function () {
      var collect = _.clone($scope.collect);
      collect.nodes = !collect.from ? mnHelper.checkboxesToList(collect.nodes).join(',') : '*';
      if (!collect.upload) {
        delete collect.uploadHost;
        delete collect.customer;
        delete collect.ticket;
      }
      var promise = mnLogsCollectInfoService.startLogsCollection(collect);
      mnPromiseHelper($scope, promise)
        .showSpinner()
        .catchErrors()
        .reloadState()
        .getPromise()
        .then(function () {
          $scope.loadingResult = true;
          $state.go('app.admin.logs.collectInfo.result');
        });
    };

    applyState(state);
    mnPoll.start($scope, function () {
      mnLogsCollectInfoService.getState()
    }).subscribe(applyState);

    mnHelper.cancelCurrentStateHttpOnScopeDestroy($scope);
  });