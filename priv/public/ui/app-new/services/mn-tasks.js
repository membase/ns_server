var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnTasks = (function () {
  "use strict";

  MnTasksService.annotations = [
    new ng.core.Injectable()
  ];

  MnTasksService.parameters = [
    ng.common.http.HttpClient,
    mn.services.MnAdmin
  ];

  MnTasksService.prototype.get = get;

  return MnTasksService;

  function MnTasksService(http, mnAdminService) {
    this.http = http;
    this.stream = {};
    this.stream.interval = new Rx.Subject();

    var tasksTypesToDisplay = {
      indexer: true,
      rebalance: true,
      orphanBucket: true,
      global_indexes: true,
      view_compaction: true,
      bucket_compaction: true,
      loadingSampleBucket: true,
      clusterLogsCollection: true
    };

    var setupInterval =
        this.stream
        .interval
        .startWith(0)
        .switchMap(function (interval) {
          return Rx.Observable.timer(interval);
        });

    var getUrl =
        mnAdminService
        .stream
        .getPoolsDefault
        .pluck("tasks", "uri")
        .distinctUntilChanged();

    this.stream.getSuccess =
      getUrl
      .combineLatest(setupInterval)
      .switchMap(this.get.bind(this))
      .publishReplay(1)
      .refCount();

    this.stream.extractNextInterval =
      this.stream
      .getSuccess
      .map(function (tasks) {
        return (_.chain(tasks)
                .pluck('recommendedRefreshPeriod')
                .compact()
                .min()
                .value() * 1000) >> 0 || 10000;
      });

    this.stream.running =
      this.stream
      .getSuccess
      .map(_.curry(_.filter)(_, function (task) {
        return task.status === "running";
      }));

    this.stream.tasksToDisplay =
      this.stream
      .running
      .map(_.curry(_.filter)(_, function (task) {
        return tasksTypesToDisplay[task.type];
      }))

  }

  function get(url) {
    return this.http.get(url[0]);
  }

})();
