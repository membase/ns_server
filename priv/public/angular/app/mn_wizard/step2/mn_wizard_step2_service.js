angular.module('mnWizardStep2Service', [
  'mnHttp'
]).factory('mnWizardStep2Service',
  function (mnHttp) {
    var mnWizardStep2Service = {
      setSelected: setSelected,
      getSelectedBuckets: getSelectedBuckets,
      getSampleBucketsRAMQuota: getSampleBucketsRAMQuota,
      isSomeBucketSelected: isSomeBucketSelected
    };
    var selectedSamples = {};

    return mnWizardStep2Service;

    function getSelectedBuckets() {
      return selectedSamples;
    }
    function setSelected(selected) {
      selectedSamples = selected;
    }
    function getSampleBucketsRAMQuota() {
      return _.reduce(selectedSamples, function (memo, num) {
        return memo + Number(num);
      }, 0);
    }
    function isSomeBucketSelected() {
      return getSampleBucketsRAMQuota() !== 0;
    }
  });