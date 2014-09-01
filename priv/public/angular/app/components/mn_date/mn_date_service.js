angular.module('mnDateService').factory('mnDateService',
  function ($http) {
    var mnDateService = {};

    mnDateService.setTimestamp = function (timestamp) {
      mnDateService.timestamp = timestamp;
    };
    mnDateService.newDate = function () {
      return (mnDateService.timestamp ? new Date(mnDateService.timestamp) : new Date());
    };

    return mnDateService;
  });
