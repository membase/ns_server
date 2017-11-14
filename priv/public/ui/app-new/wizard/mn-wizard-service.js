var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnWizard = (function () {
  "use strict";

  var wizardForm = {
    newCluster: new ng.forms.FormGroup({
      clusterName: new ng.forms.FormControl(null, [
        ng.forms.Validators.required
      ]),
      user: new ng.forms.FormGroup({
        username: new ng.forms.FormControl("Administrator", [
          ng.forms.Validators.required
        ]),
        password: new ng.forms.FormControl(null, [
          ng.forms.Validators.required,
          ng.forms.Validators.minLength(6)
        ]),
        passwordVerify: new ng.forms.FormControl()
      })
    }),
    newClusterConfig: new ng.forms.FormGroup({
      clusterStorage: new ng.forms.FormGroup({
        hostname: new ng.forms.FormControl(null, [
          ng.forms.Validators.required
        ]),
        storage: new ng.forms.FormGroup({
          path: new ng.forms.FormControl(null),
          index_path: new ng.forms.FormControl(null)
        })
      }),
      services: new ng.forms.FormGroup({
        flag: new ng.forms.FormGroup({
          kv: new ng.forms.FormControl({value: true, disabled: true}),
          index: new ng.forms.FormControl(true),
          fts: new ng.forms.FormControl(true),
          n1ql: new ng.forms.FormControl(true),
          eventing: new ng.forms.FormControl(true)
        }),
        field: new ng.forms.FormGroup({
          kv: new ng.forms.FormControl(null),
          index: new ng.forms.FormControl(null),
          fts: new ng.forms.FormControl(null)
        })
      }),
      storageMode: new ng.forms.FormControl(null),
      enableStats: new ng.forms.FormControl(true)
    }),
    termsAndConditions: new ng.forms.FormGroup({
      agree: new ng.forms.FormControl(false),
      register: new ng.forms.FormControl(false),
      user: new ng.forms.FormGroup({
        firstname: new ng.forms.FormControl(),
        lastname: new ng.forms.FormControl(),
        company: new ng.forms.FormControl(),
        email: new ng.forms.FormControl(null, [
          ng.forms.Validators.email
        ])
      })
    }),
    // joinCluster: {
    //   clusterMember: {
    //     hostname: "127.0.0.1",
    //     username: "Administrator",
    //     password: ''
    //   },
    //   services: {
    //     disabled: {kv: false, index: false, n1ql: false, fts: false, eventing: false},
    //     model: {kv: true, index: true, n1ql: true, fts: true, eventing: true}
    //   },
    //   firstTimeAddedServices: undefined
    // }
  };

  MnWizardService.annotations = [
    new ng.core.Injectable()
  ];

  MnWizardService.parameters = [
    ng.common.http.HttpClient
  ];


  MnWizardService.prototype.getSelfConfig = getSelfConfig;
  MnWizardService.prototype.getCELicense = getCELicense;
  MnWizardService.prototype.getEELicense = getEELicense;
  MnWizardService.prototype.createLookUpStream = createLookUpStream;
  MnWizardService.prototype.postAuth = postAuth;
  MnWizardService.prototype.postHostname = postHostname;
  MnWizardService.prototype.postDiskStorage = postDiskStorage;
  MnWizardService.prototype.postIndexes = postIndexes;
  MnWizardService.prototype.postServices = postServices;
  MnWizardService.prototype.postStats = postStats;
  MnWizardService.prototype.postEmail = postEmail;

  return MnWizardService;

  function MnWizardService(http) {
    this.http = http;
    this.wizardForm = wizardForm;

    this.stream = {};

    this.stream.diskStorageHttp =
      new mn.helper.MnPostHttp(this.postDiskStorage.bind(this))
      .addSuccess()
      .addError();

    this.stream.hostnameHttp =
      new mn.helper.MnPostHttp(this.postHostname.bind(this))
      .addSuccess()
      .addError();

    this.stream.authHttp =
      new mn.helper.MnPostHttp(this.postAuth.bind(this))
      .addSuccess()
      .addError();

    this.stream.emailHttp =
      new mn.helper.MnPostHttp(this.postEmail.bind(this));

    this.stream.indexesHttp =
      new mn.helper.MnPostHttp(this.postIndexes.bind(this))
      .addSuccess()
      .addError();

    this.stream.servicesHttp =
      new mn.helper.MnPostHttp(this.postServices.bind(this))
      .addSuccess()
      .addError();

    this.stream.statsHttp =
      new mn.helper.MnPostHttp(this.postStats.bind(this))
      .addSuccess()
      .addError();

    this.stream.getSelfConfig =
      (new Rx.BehaviorSubject())
      .switchMap(this.getSelfConfig.bind(this))
      .shareReplay(1);

    this.stream.preprocessPath =
      this.stream
      .getSelfConfig
      .map(chooseOSPathPreprocessor);

    this.stream.availableHddStorage =
      this.stream
      .getSelfConfig
      .pluck("availableStorage", "hdd")
      .map(function (hdd) {
        return hdd.sort(function (a, b) {
          return b.path.length - a.path.length;
        });
      });

    this.stream.initHddStorage =
      this.stream
      .getSelfConfig
      .pluck("storage", "hdd", 0);

    var storageGroup =
        this.wizardForm
        .newClusterConfig
        .get("clusterStorage.storage");

    this.stream.lookUpDBPath = this.createLookUpStream(
      storageGroup
        .valueChanges
        .pluck("path")
        .distinctUntilChanged());

    this.stream.lookUpIndexPath = this.createLookUpStream(
      storageGroup
        .valueChanges
        .pluck("index_path")
        .distinctUntilChanged());

    this.stream.totalRAMMegs =
      this.stream
      .getSelfConfig
      .map(function (nodeConfig) {
        return Math.floor(nodeConfig.storageTotals.ram.total / mn.helper.IEC.Mi);
      });

    this.stream.maxRAMMegs =
      this.stream
      .totalRAMMegs
      .map(mn.helper.calculateMaxMemorySize);
  }

  function createLookUpStream(subject) {
    return Rx.Observable.combineLatest(
      this.stream.availableHddStorage,
      this.stream.preprocessPath,
      subject)
      .map(lookupPathResource)
      .map(updateTotal);
  }

  function updateTotal(pathResource) {
    return Math.floor(
      pathResource.sizeKBytes * (100 - pathResource.usagePercent) / 100 / mn.helper.IEC.Mi
    ) + ' GB';
  }

  function lookupPathResource(rv) {
    var notFound = {path: "/", sizeKBytes: 0, usagePercent: 0};
    if (!rv[2]) {
      return notFound;
    } else {
      return _.detect(rv[0], function (info) {
        var preproc = rv[1](info.path);
        return rv[1](rv[2]).substring(0, preproc.length) == preproc;
      }) || notFound;
    }
  }

  function chooseOSPathPreprocessor(config) {
    return (
      (config.os === 'windows') ||
        (config.os === 'win64') ||
        (config.os === 'win32')
    ) ? preprocessPathForWindows : preprocessPathStandard;
  }

  function preprocessPathStandard(p) {
    if (p.charAt(p.length-1) != '/') {
      p += '/';
    }
    return p;
  }

  function preprocessPathForWindows(p) {
    p = p.replace(/\\/g, '/');
    if ((/^[A-Z]:\//).exec(p)) { // if we're using uppercase drive letter downcase it
      p = String.fromCharCode(p.charCodeAt(0) + 0x20) + p.slice(1);
    }
    return preprocessPathStandard(p);
  }

  function getCELicense() {
    return this.http.get("CE_license_agreement.txt", {responseType: 'text'});
  }

  function getEELicense() {
    return this.http.get("EE_subscription_license_agreement.txt", {responseType: 'text'});
  }

  function getSelfConfig() {
    return this.http.get('/nodes/self');
  }

  function postStats(sendStats) {
    return this.http.post('/settings/stats', {
      sendStats: sendStats
    });
  }

  function postEmail(register) {
    var params = new ng.common.http.HttpParams({encoder: new mn.helper.MnHttpEncoder()});
    for (var i in register[0]) {
      params = params.set(i, register[0][i]);
    }
    params = params.set("version", register[1]);
    return this.http.jsonp('http://ph.couchbase.net/email?' + params.toString(), "callback");
  }

  function postServices(services) {
    return this.http.post('/node/controller/setupServices', {
      services: services.join(",")
    });
  }

  function postIndexes(data) {
    return this.http.post('/settings/indexes', data);
  }

  function postAuth(user) {
    var data = _.clone(user[0]);
    delete data.verifyPassword;
    data.port = "SAME";

    return this.http.post('/settings/web', data, {
      params: new ng.common.http.HttpParams().set("just_validate", user[1] ? 1 : 0)
    });
  }

  function postDiskStorage(config) {
    return this.http.post('/nodes/self/controller/settings', config);
  }
  function postHostname(hostname) {
    return this.http.post('/node/controller/rename', {
      hostname: hostname
    });
  }
  function postJoinCluster(clusterMember) {
    clusterMember.user = clusterMember.username;
    return this.http.post('/node/controller/doJoinCluster', clusterMember)
  }

})();
