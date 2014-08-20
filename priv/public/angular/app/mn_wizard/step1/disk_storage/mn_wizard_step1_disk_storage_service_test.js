describe("mnWizardStep1DiskStorageService", function () {
  var mnWizardStep1DiskStorageService;
  var $httpBackend;
  var self;

  beforeEach(angular.mock.module('mnWizard'));

  beforeEach(inject(function ($injector) {
    $httpBackend = $injector.get('$httpBackend');
    mnWizardStep1DiskStorageService = $injector.get('mnWizardStep1DiskStorageService');
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
    mnWizardStep1DiskStorageService.populateModel(self);
  }

  it('should be properly initialized', function () {
    expect(mnWizardStep1DiskStorageService.model).toEqual(jasmine.any(Object));
    expect(mnWizardStep1DiskStorageService.populateModel).toEqual(jasmine.any(Function));
    expect(mnWizardStep1DiskStorageService.postDiskStorage).toEqual(jasmine.any(Function));
    expect(mnWizardStep1DiskStorageService.lookup).toEqual(jasmine.any(Function));
    expect(mnWizardStep1DiskStorageService.model.dbPath).toEqual('');
    expect(mnWizardStep1DiskStorageService.model.indexPath).toEqual('');
  });

  it('should be properly populated', function () {
    populate();
    expect(mnWizardStep1DiskStorageService.model.dbPath).toEqual('/home/pavel/projects/couchbase/ns_server/data/n_0/data');
    expect(mnWizardStep1DiskStorageService.model.indexPath).toEqual('/home/pavel/projects/couchbase/ns_server/data/n_0/data');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[0].path).toEqual('/run/lock/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[1].path).toEqual('/run/shm/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[2].path).toEqual('/home/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[3].path).toEqual('/dev/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[4].path).toEqual('/run/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[5].path).toEqual('/');
  });

  it('should be able to send requests', function () {
    populate();
    $httpBackend.expectPOST('/nodes/self/controller/settings', 'path=/home/pavel/projects/couchbase/ns_server/data/n_0/data&index_path=/home/pavel/projects/couchbase/ns_server/data/n_0/data').respond(200);
    mnWizardStep1DiskStorageService.postDiskStorage();
    $httpBackend.flush();
  });

  it('should working with cloned version of hdd list', function () {
    populate();
    expect(self.availableStorage).not.toBe(mnWizardStep1DiskStorageService.model.availableStorage);
    expect(mnWizardStep1DiskStorageService.model.availableStorage[5]).not.toBe(self.availableStorage[0]);
  });

  it('should properly lookup path', function () {
    populate();
    expect(mnWizardStep1DiskStorageService.lookup('/run/s')).toEqual({
      "path": "/run/",
      "sizeKBytes": 604624,
      "usagePercent":1
    });
    expect(mnWizardStep1DiskStorageService.lookup('/home/')).toEqual({
      "path":"/home/",
      "sizeKBytes": 259326248,
      "usagePercent": 14
    });
    expect(mnWizardStep1DiskStorageService.lookup('/home')).toEqual({
      "path":"/home/",
      "sizeKBytes": 259326248,
      "usagePercent": 14
    });
    expect(mnWizardStep1DiskStorageService.lookup('/hom')).toEqual({
      "path": "/",
      "sizeKBytes": 42288960,
      "usagePercent": 41
    });
    expect(mnWizardStep1DiskStorageService.lookup('/')).toEqual({
      "path": "/",
      "sizeKBytes": 42288960,
      "usagePercent": 41
    });
    expect(mnWizardStep1DiskStorageService.lookup('')).toEqual({
      "path": "/",
      "sizeKBytes": 0,
      "usagePercent": 0
    });
  });

  it('should properly working on windows', function () {
    populate('windows');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[0].path).toEqual('a:/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[1].path).toEqual('b:/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[2].path).toEqual('c:/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[3].path).toEqual('d:/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[4].path).toEqual('e:/');
    expect(mnWizardStep1DiskStorageService.model.availableStorage[5].path).toEqual('f:/');
  });

});