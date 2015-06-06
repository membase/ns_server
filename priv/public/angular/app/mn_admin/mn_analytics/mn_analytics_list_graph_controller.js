angular.module('mnAnalytics').controller('mnAnalyticsListGraphController',
  function ($scope, $stateParams) {
    $scope.$watch('state', function (analiticsState) {
      if (!analiticsState || !analiticsState.statsByName) {
        return;
      }

      var selectedStat = analiticsState.statsByName[$stateParams.graph];
      if (!selectedStat) {
        return;
      }

      // notify plot of small graphs about selection
      selectedStat.config.isSelected = true;
      $scope.$on('$destroy', function () {
        selectedStat.config.isSelected = false;
      });

      selectedStat.visiblePeriod = Math.ceil(Math.min(selectedStat.config.zoomMillis, analiticsState.stats.serverDate - selectedStat.config.timestamp[0]) / 1000);
      selectedStat.graphConfig = {
        stats: selectedStat.config.data,
        tstamps: selectedStat.config.timestamp,
        options: {
          color: '#1d88ad',
          verticalMargin: 1.02,
          fixedTimeWidth: selectedStat.config.zoomMillis,
          timeOffset: selectedStat.config.timeOffset,
          lastSampleTime: selectedStat.config.now,
          breakInterval: selectedStat.config.breakInterval,
          maxY: selectedStat.config.maxY,
          isBytes: selectedStat.config.isBytes
        }
      };
      $scope.selectedStat = selectedStat;
    });
  });