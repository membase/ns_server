var mn = mn || {};
mn.services = mn.services || {};
mn.services.MnWizard = (function () {
  "use strict";

  var clusterStorage = new ng.forms.FormGroup({
    hostname: new ng.forms.FormControl(null, [
      ng.forms.Validators.required
    ]),
    storage: new ng.forms.FormGroup({
      path: new ng.forms.FormControl(null),
      index_path: new ng.forms.FormControl(null),
      cbas_path: new ng.forms.FormArray([
        new ng.forms.FormControl()
      ])
    })
  });

  var querySettings =  new ng.forms.FormGroup({
    queryTmpSpaceDir: new ng.forms.FormControl(null),
    queryTmpSpaceSize: new ng.forms.FormControl(null),
  });

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
      clusterStorage: clusterStorage,
      querySettings: querySettings,
      services: new ng.forms.FormGroup({
        flag: new ng.forms.FormGroup({
          kv: new ng.forms.FormControl({value: true, disabled: true}),
          index: new ng.forms.FormControl(true),
          fts: new ng.forms.FormControl(true),
          n1ql: new ng.forms.FormControl(true),
          eventing: new ng.forms.FormControl(true),
          cbas: new ng.forms.FormControl(false)
        }),
        field: new ng.forms.FormGroup({
          kv: new ng.forms.FormControl(null),
          index: new ng.forms.FormControl(null),
          fts: new ng.forms.FormControl(null),
          cbas: new ng.forms.FormControl(null)
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
    joinCluster: new ng.forms.FormGroup({
      clusterAdmin: new ng.forms.FormGroup({
        hostname: new ng.forms.FormControl("127.0.0.1", [
          ng.forms.Validators.required
        ]),
        user: new ng.forms.FormControl("Administrator", [
          ng.forms.Validators.required
        ]),
        password: new ng.forms.FormControl('', [
          ng.forms.Validators.required
        ])
      }),
      services: new ng.forms.FormGroup({
        flag: new ng.forms.FormGroup({
          kv: new ng.forms.FormControl(true),
          index: new ng.forms.FormControl(true),
          fts: new ng.forms.FormControl(true),
          n1ql: new ng.forms.FormControl(true),
          eventing: new ng.forms.FormControl(true),
          cbas: new ng.forms.FormControl(false)
        })
      }),
      clusterStorage: clusterStorage,
      querySettings: querySettings
    })
  };

  MnWizardService.annotations = [
    new ng.core.Injectable()
  ];

  MnWizardService.parameters = [
    ng.common.http.HttpClient,
    mn.services.MnAdmin
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
  MnWizardService.prototype.postQuerySettings = postQuerySettings;
  MnWizardService.prototype.postStats = postStats;
  MnWizardService.prototype.postEmail = postEmail;
  MnWizardService.prototype.postJoinCluster = postJoinCluster;
  MnWizardService.prototype.getServicesValues = getServicesValues;
  MnWizardService.prototype.getUserCreds = getUserCreds;
  MnWizardService.prototype.getQuerySettings = getQuerySettings;

  return MnWizardService;

  function MnWizardService(http, mnAdminService) {
    this.http = http;
    this.wizardForm = wizardForm;

    this.stream = {};
    this.initialValues = {
      hostname: null,
      storageMode: null,
      clusterStorage: null,
      implementationVersion: null
    };

    this.stream.joinClusterHttp =
      new mn.helper.MnPostHttp(this.postJoinCluster.bind(this))
      .addSuccess()
      .addLoading()
      .addError();

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

    this.stream.querySettingsHttp =
      new mn.helper.MnPostHttp(this.postQuerySettings.bind(this))
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

    this.stream.groupHttp =
      new mn.helper.MnPostGroupHttp({
        poolsDefaultHttp: mnAdminService.stream.poolsDefaultHttp,
        servicesHttp: this.stream.servicesHttp,
        diskStorageHttp: this.stream.diskStorageHttp,
        querySettingsHttp: this.stream.querySettingsHttp,
        hostnameHttp: this.stream.hostnameHttp,
        statsHttp: this.stream.statsHttp
      })
      .addLoading()
      .addSuccess();

    this.stream.secondGroupHttp =
      new mn.helper.MnPostGroupHttp({
        indexesHttp: this.stream.indexesHttp,
        authHttp: this.stream.authHttp
      })
      .addLoading()
      .addSuccess();

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
      .pluck("storage", "hdd", 0)
      .map(function (rv) {
        rv.cbas_path = rv.cbas_dirs;
        delete rv.cbas_dirs;
        return rv;
      });

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

  function getServicesValues(servicesGroup) {
    return _.reduce(
      ["kv", "index", "fts", "n1ql", "eventing"],
      function (result, serviceName) {
        var service = servicesGroup.get(serviceName);
        if (service && service.value) {
          result.push(serviceName);
        }
        return result;
      }, []);
  }

  function getUserCreds() {
    var data = _.clone(this.wizardForm.newCluster.value.user);
    data.user = data.username
    delete data.passwordVerify;
    delete data.username;
    return data;
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

  function getQuerySettings() {
    return this.http.get("/settings/querySettings");
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

  function postServices(data) {
    return this.http.post('/node/controller/setupServices', data);
  }

  function postQuerySettings(data) {
    return this.http.post("/settings/querySettings", data);
  }

  function postIndexes(data) {
    return this.http.post('/settings/indexes', data);
  }

  function postAuth(user) {
    var data = _.clone(user[0]);
    delete data.passwordVerify;
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
    return this.http.post('/node/controller/doJoinCluster', clusterMember)
  }

})();
