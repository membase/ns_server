describe("wizard.step1.diskStorage.service", function () {
  var diskStorageService;
  var $httpBackend;
  var self;

  beforeEach(angular.mock.module('wizard'));

  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    diskStorageService = $injector.get('wizard.step1.diskStorage.service');
  }));

  function populate(os) {
    var isWindows = os == "windows";
    self = {
      "hddStorage": {
        "path": "/home/pavel/projects/couchbase/ns_server/data/n_0/data",
        "index_path": "/home/pavel/projects/couchbase/ns_server/data/n_0/data",
        "quotaMb": "none",
        "state": "ok"
      },
      "os": os || "Ubuntu",
      "availableStorage": [{
          "path": isWindows ? "A:\\" : "/",
          "sizeKBytes": 42288960,
          "usagePercent": 41
        }, {
          "path": isWindows ? "B:\\" : "/dev",
          "sizeKBytes": 3014292,
          "usagePercent": 1
        }, {
          "path": isWindows ? "C:\\" : "/run",
          "sizeKBytes": 604624,
          "usagePercent":1
        }, {
          "path": isWindows ? "D:\\" : "/run/lock",
          "sizeKBytes": 5120,
          "usagePercent": 0
        }, {
          "path": isWindows ? "E:\\" : "/run/shm",
          "sizeKBytes": 3023100,
          "usagePercent": 1
        }, {
          "path": isWindows ? "F:\\" : "/home",
          "sizeKBytes": 259326248,
          "usagePercent": 14
        }]
    };
    diskStorageService.populateModel(self);
  }

  it('should be properly initialized', function () {
    expect(diskStorageService.model).toEqual(jasmine.any(Object));
    expect(diskStorageService.populateModel).toEqual(jasmine.any(Function));
    expect(diskStorageService.postDiskStorage).toEqual(jasmine.any(Function));
    expect(diskStorageService.lookup).toEqual(jasmine.any(Function));
    expect(diskStorageService.model.dbPath).toEqual('');
    expect(diskStorageService.model.indexPath).toEqual('');
  });

  it('should be properly populated', function () {
    populate();
    expect(diskStorageService.model.dbPath).toEqual('/home/pavel/projects/couchbase/ns_server/data/n_0/data');
    expect(diskStorageService.model.indexPath).toEqual('/home/pavel/projects/couchbase/ns_server/data/n_0/data');
    expect(diskStorageService.model.availableStorage[0].path).toEqual('/run/lock/');
    expect(diskStorageService.model.availableStorage[1].path).toEqual('/run/shm/');
    expect(diskStorageService.model.availableStorage[2].path).toEqual('/home/');
    expect(diskStorageService.model.availableStorage[3].path).toEqual('/dev/');
    expect(diskStorageService.model.availableStorage[4].path).toEqual('/run/');
    expect(diskStorageService.model.availableStorage[5].path).toEqual('/');
  });

  it('should be able to send requests', function () {
    populate();
    $httpBackend.expectPOST('/nodes/self/controller/settings', 'path=/home/pavel/projects/couchbase/ns_server/data/n_0/data&index_path=/home/pavel/projects/couchbase/ns_server/data/n_0/data').respond(200);
    diskStorageService.postDiskStorage();
    $httpBackend.flush();
  });

  it('should working with cloned version of hdd list', function () {
    populate();
    expect(self.availableStorage).not.toBe(diskStorageService.model.availableStorage);
    expect(diskStorageService.model.availableStorage[5]).not.toBe(self.availableStorage[0]);
  });

  it('should properly lookup path', function () {
    populate();
    expect(diskStorageService.lookup('/run/s')).toEqual({
      "path": "/run/",
      "sizeKBytes": 604624,
      "usagePercent":1
    });
    expect(diskStorageService.lookup('/home/')).toEqual({
      "path":"/home/",
      "sizeKBytes": 259326248,
      "usagePercent": 14
    });
    expect(diskStorageService.lookup('/home')).toEqual({
      "path":"/home/",
      "sizeKBytes": 259326248,
      "usagePercent": 14
    });
    expect(diskStorageService.lookup('/hom')).toEqual({
      "path": "/",
      "sizeKBytes": 42288960,
      "usagePercent": 41
    });
    expect(diskStorageService.lookup('/')).toEqual({
      "path": "/",
      "sizeKBytes": 42288960,
      "usagePercent": 41
    });
    expect(diskStorageService.lookup('')).toEqual({
      "path": "/",
      "sizeKBytes": 0,
      "usagePercent": 0
    });
  });

  it('should properly working on windows', function () {
    populate('windows');
    expect(diskStorageService.model.availableStorage[0].path).toEqual('a:/');
    expect(diskStorageService.model.availableStorage[1].path).toEqual('b:/');
    expect(diskStorageService.model.availableStorage[2].path).toEqual('c:/');
    expect(diskStorageService.model.availableStorage[3].path).toEqual('d:/');
    expect(diskStorageService.model.availableStorage[4].path).toEqual('e:/');
    expect(diskStorageService.model.availableStorage[5].path).toEqual('f:/');
  });

});