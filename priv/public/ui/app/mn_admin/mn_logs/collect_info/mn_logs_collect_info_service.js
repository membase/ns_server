(function () {
  "use strict";

  angular.module('mnLogsCollectInfoService', [
    'mnHttp',
    'mnServersService',
    'mnTasksDetails',
    'mnFilters'
  ]).service('mnLogsCollectInfoService', mnLogsCollectInfoServiceFactory);

  function mnLogsCollectInfoServiceFactory(mnHttp, $q, mnServersService, mnTasksDetails, mnStripPortHTMLFilter) {
    var mnLogsCollectInfoService = {
      startLogsCollection: startLogsCollection,
      cancelLogsCollection: cancelLogsCollection,
      getState: getState
    };

    return mnLogsCollectInfoService;

    function startLogsCollection(collect) {
      return mnHttp.post('/controller/startLogsCollection', collect);
    }
    function cancelLogsCollection() {
      return mnHttp.post('/controller/cancelLogsCollection');
    }
    function getState() {
      return $q.all([
        mnServersService.getNodes(),
        mnTasksDetails.get()
      ]).then(function (resp) {

        var nodes = resp[0].allNodes;
        var tasks = resp[1].tasks;
        var task = _.detect(tasks, function (taskInfo) {
          return taskInfo.type === "clusterLogsCollection";
        });
        if (!task) {
          return {
            nodesByStatus: {},
            nodeErrors: [],
            status: 'idle',
            perNode: {},
            nodes: nodes
          };
        }

        task = JSON.parse(JSON.stringify(task));

        var perNodeHash = task.perNode;
        var perNode = [];

        var cancallable = "starting started startingUpload startedUpload".split(" ");

        _.each(perNodeHash, function (ni, nodeName) {
          var node = _.detect(nodes, function (n) {
            return n.otpNode === nodeName;
          });

          ni.nodeName = (node === undefined) ? nodeName.replace(/^.*?@/, '') : mnStripPortHTMLFilter(node.hostname, nodes);
          perNode.push(ni);
          // possible per-node statuses are:
          //      starting, started, failed, collected,
          //      startingUpload, startedUpload, failedUpload, uploaded

          if (task.status == 'cancelled' && cancallable.indexOf(ni.status) >= 0) {
            ni.status = 'cancelled';
          }
        });

        var nodesByStatus = _.groupBy(perNode, 'status');

        var nodeErrors = _.compact(_.map(perNode, function (ni) {
          if (ni.uploadOutput) {
            return {nodeName: ni.nodeName, error: ni.uploadOutput};
          }
        }));

        task.nodesByStatus = nodesByStatus;
        task.nodeErrors = nodeErrors;
        task.nodes = nodes;

        return task
      });
    }
  }
})();
