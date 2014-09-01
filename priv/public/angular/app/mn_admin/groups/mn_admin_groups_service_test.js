describe("mnAdminGroupsService", function () {
  var $httpBackend;
  var mnAdminGroupsService;

  beforeEach(angular.mock.module('mnAdminGroupsService'));
  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnAdminGroupsService = $injector.get('mnAdminGroupsService');
  }));

  it('should be properly initialized', function () {
    expect(mnAdminGroupsService.model).toEqual(jasmine.any(Object));
    expect(mnAdminGroupsService.getGroups).toEqual(jasmine.any(Function));
    expect(mnAdminGroupsService.setIsGroupsAvailable).toEqual(jasmine.any(Function));
  });

  it('should get buckets detailed', function () {
    $httpBackend.expectGET('uri').respond(200, {"groups":[{"name":"Group 1","uri":"/pools/default/serverGroups/0","addNodeURI":"/pools/default/serverGroups/0/addNode","nodes":[{"systemStats":{"cpu_utilization_rate":33.67346938775511,"swap_total":6291451904,"swap_used":84033536,"mem_total":6191300608,"mem_free":1421852672},"interestingStats":{"cmd_get":0,"couch_docs_actual_disk_size":8450862,"couch_docs_data_size":8435712,"couch_views_actual_disk_size":0,"couch_views_data_size":0,"curr_items":0,"curr_items_tot":0,"ep_bg_fetched":0,"get_hits":0,"mem_used":32834768,"ops":0,"vb_replica_curr_items":0},"uptime":"23433","memoryTotal":6191300608,"memoryFree":1421852672,"mcdMemoryReserved":4723,"mcdMemoryAllocated":4723,"couchApiBase":"http://127.0.0.1:9501/","otpCookie":"fsjlhgytmslzhsrl","clusterMembership":"active","recoveryType":"none","status":"healthy","otpNode":"n_1@127.0.0.1","thisNode":true,"hostname":"127.0.0.1:9001","clusterCompatibility":196608,"version":"3.0.0r-910-g9a4e7bb","os":"x86_64-pc-linux-gnu","ports":{"proxy":12003,"direct":12002}}]}],"uri":"/pools/default/serverGroups?rev=50325746"});
    mnAdminGroupsService.getGroups('uri');
    $httpBackend.flush();

    expect(mnAdminGroupsService.model.hostnameToGroup).toEqual({"127.0.0.1:9001":{"name":"Group 1","uri":"/pools/default/serverGroups/0","addNodeURI":"/pools/default/serverGroups/0/addNode","nodes":[{"systemStats":{"cpu_utilization_rate":33.67346938775511,"swap_total":6291451904,"swap_used":84033536,"mem_total":6191300608,"mem_free":1421852672},"interestingStats":{"cmd_get":0,"couch_docs_actual_disk_size":8450862,"couch_docs_data_size":8435712,"couch_views_actual_disk_size":0,"couch_views_data_size":0,"curr_items":0,"curr_items_tot":0,"ep_bg_fetched":0,"get_hits":0,"mem_used":32834768,"ops":0,"vb_replica_curr_items":0},"uptime":"23433","memoryTotal":6191300608,"memoryFree":1421852672,"mcdMemoryReserved":4723,"mcdMemoryAllocated":4723,"couchApiBase":"http://127.0.0.1:9501/","otpCookie":"fsjlhgytmslzhsrl","clusterMembership":"active","recoveryType":"none","status":"healthy","otpNode":"n_1@127.0.0.1","thisNode":true,"hostname":"127.0.0.1:9001","clusterCompatibility":196608,"version":"3.0.0r-910-g9a4e7bb","os":"x86_64-pc-linux-gnu","ports":{"proxy":12003,"direct":12002}}]}});
  });

});