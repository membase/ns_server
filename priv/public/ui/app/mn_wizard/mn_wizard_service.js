(function () {
  "use strict";

  angular
    .module('mnWizardService', [])
    .factory('mnWizardService', mnWizardServiceFactory);

  function mnWizardServiceFactory($http) {
    var mnWizardService = {
      getNewClusterState: getNewClusterState,
      getState: getState,
      getTermsAndConditionsState: getTermsAndConditionsState,
      getCELicense: getCELicense,
      getEELicense: getEELicense
    };
    var state = {
      isNewCluster: undefined,
      newClusterState: {
        clusterName: "",
        user: {
          username: 'Administrator',
          password: '',
          verifyPassword: ''
        }
      },
      termsAndConditionsState: {
        email: '',
        firstname: '',
        lastname: '',
        company: '',
        version: ''
      }
    };


    return mnWizardService;

    function getCELicense() {
      return $http({
        method: "GET",
        url: "CE_license_agreement.txt"
      }).then(function (resp) {
        return resp.data;
      });
    }

    function getEELicense() {
      return $http({
        method: "GET",
        url: "EE_subscription_license_agreement.txt"
      }).then(function (resp) {
        return resp.data;
      });
    }

    function getState() {
      return state;
    }

    function getNewClusterState() {
      return state.newClusterState;
    }

    function getTermsAndConditionsState() {
      return state.termsAndConditionsState;
    }

  }
})();
