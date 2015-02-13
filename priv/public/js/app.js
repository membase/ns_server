/**
   Copyright 2015 Couchbase, Inc.

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
 **/
function performSignOut() {
  if (ModalAction.isActive()) {
    $(window).one('modal-action:complete', function () {performSignOut()});
    return;
  }

  $(window).trigger('hashchange'); // this will close all dialogs

  $(document.body).addClass('auth');
  var spinner = overlayWithSpinner('#login_form', false);
  $('.sign-out-link').hide();

  DAL.initiateLogout(function () {
    spinner.remove();
    DAL.onReady(function () {
      if (DAL.login)
        $('.sign-out-link').show();
    });

    _.defer(function () {
      var e = $('#auth_dialog [name=login]').get(0);
      try {e.focus();} catch (ex) {}
    });
  });
}

;(function () {
  var weekDays = "Sun Mon Tue Wed Thu Fri Sat".split(' ');
  var monthNames = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split(' ');
  function _2digits(d) {
    d += 100;
    return String(d).substring(1);
  }

  window.formatAlertTStamp = formatAlertTStamp;
  function formatAlertTStamp(mseconds) {
    var date = new Date(mseconds);
    var rv = [weekDays[date.getDay()],
      ' ',
      monthNames[date.getMonth()],
      ' ',
      date.getDate(),
      ' ',
      _2digits(date.getHours()), ':', _2digits(date.getMinutes()), ':', _2digits(date.getSeconds()),
      ' ',
      date.getFullYear()];

    return rv.join('');
  }

  window.formatLogTStamp = function formatLogTStamp(jsonDate) {
    var date = new Date(jsonDate);
    var rv = [
      "<strong>",
      _2digits(date.getUTCHours()), ':', _2digits(date.getUTCMinutes()), ':', _2digits(date.getUTCSeconds()),
      "</strong> - ",
      weekDays[date.getUTCDay()],
      ' ',
      monthNames[date.getUTCMonth()],
      ' ',
      date.getUTCDate(),
      ', ',
      date.getUTCFullYear()];

    return rv.join('');
  };

  window.formatTime = function formatTime(mseconds) {
    var date = new Date(mseconds);
    var rv = [
      _2digits(date.getHours()), ':',
      _2digits(date.getMinutes()), ':',
      _2digits(date.getSeconds())];
    return rv.join('');
  };


})();

function formatAlertType(type) {
  switch (type) {
  case 'warning':
    return "Warning";
  case 'attention':
    return "Needs Your Attention";
  case 'info':
    return "Informative";
  }
}

var ThePage = {
  sections: {overview: OverviewSection,
             servers: ServersSection,
             groups: ServerGroupsSection,
             analytics: AnalyticsSection,
             buckets: BucketsSection,
             views: ViewsSection,
             replications: ReplicationsSection,
             documents: DocumentsSection,
             log: LogsSection,
             settings: SettingsSection,
             indexes: IndexesSection},

  coming: {alerts:true},

  currentSection: null,
  currentSectionName: null,
  signOut: function () {
    performSignOut();
  },
  ensureSection: function (section) {
    if (this.currentSectionName != section)
      this.gotoSection(section);
  },
  gotoSection: function (section) {
    if (!(this.sections[section])) {
      throw new Error('unknown section:' + section);
    }
    if (this.currentSectionName == section) {
      if ('navClick' in this.currentSection)
        this.currentSection.navClick();
      else
        this.currentSection.onEnter();
    } else
      setHashFragmentParam('sec', section);
  },
  initialize: function () {
    var self = this;

    function preventKeys(e) {
      if (e.keyCode === 27) { //esc
        e.preventDefault();
      }
    }
    $(document).keydown(preventKeys).keypress(preventKeys);

    _.each(_.uniq(_.values(this.sections)), function (sec) {
      if (sec.init)
        sec.init();
    });

    initAlertsSubscriber();

    DAL.cells.mode.subscribeValue(function (sec) {
      $('.currentNav').removeClass('currentNav');
      $('.switch_' + sec).parent('li').addClass('currentNav');

      var oldSection = self.currentSection;
      var currentSection = self.sections[sec];
      if (!currentSection) {
        return;
      }
      self.currentSectionName = sec;
      self.currentSection = currentSection;

      var secId = sec;
      if (currentSection.domId != null) {
        secId = currentSection.domId(sec);
      }

      if (self.coming[sec] == true && window.location.href.indexOf("FORCE") < 0) {
        secId = 'coming';
      }

      $('#mainPanel > div:not(.notice)').css('display', 'none');
      $('#js_' + secId).css('display','block');

      _.defer(function () {
        if (oldSection && oldSection.onLeave)
          oldSection.onLeave();
        self.currentSection.onEnter();
        $(window).trigger('sec:' + sec);
      });
    });

    DAL.onReady(function () {
      if (DAL.login) {
        $('.sign-out-link').show();
      }
    });

    watchHashParamChange('sec', 'overview', function (sec) {
      DAL.switchSection(sec);
    });
    _.defer(function() {
      $(window).trigger('hashchange');
    });
  }
};

function hideAuthForm() {
  $(document.body).removeClass('auth');
}

function showFailedMessage(text) {
  $('#auth_failed_message .al_text').text(text);
  $('#auth_failed_message').show();
}

function loginFormSubmit() {
  var login = $('#login_form [name=login]').val();
  var password = $('#login_form [name=password]').val();
  var spinner = overlayWithSpinner('#login_form', false);
  $('#auth_dialog .alert_red').hide();
  $('#login_form').addClass('noform');
  DAL.performLogin(login, password, function (status, xhr) {
    spinner.remove();
    $('#login_form').removeClass('noform');

    if (status == 'success') {
      hideAuthForm();
      // don't keep credentials in DOM tree
      $('#login_form')[0].reset();
      return;
    }

    showFailedMessage(IOCenter.isNotFound(xhr) ? 'Login failed. Try again.' : 'Lost connection to the server.');
  });
  return false;
}

var SetupWizard = {
  show: function(page, opt, isContinuation) {
    opt = opt || {};
    page = page || "welcome";

    var pageNames = _.keys(SetupWizard.pages);

    for (var i = 0; i < pageNames.length; i++) {
      if (page == pageNames[i]) {
        var rv;
        if (!isContinuation && SetupWizard.pages[page]) {
          rv = SetupWizard.pages[page]('self', 'init_' + page, opt);
        }
        // if page is in continuation passing style, call it
        // passing continuation and return.  This allows page to do
        // async computation and then resume dialog page switching
        if (rv instanceof Function) {
          $('body, html').css('cursor', 'wait');

          return rv(function () {

            $('body, html').css('cursor', '');
            // we don't pass real continuation, we just call ourselves again
            SetupWizard.show(page, opt, true);
          });
        }
        $(document.body).addClass('init_' + page);
        $('html, body').animate({scrollTop:0},250);
        _.defer(function () {
          var element = $('.focusme:visible').get(0)
          if (!element) {
            return;
          }
          try {element.focus();} catch (e) {}
        });
      }
    }

    if (page == 'done')
      DAL.enableSections();

    // Hiding other pages in a 2nd loop to prevent "flashing" between pages
    for (var i = 0; i < pageNames.length; i++) {
      if (page != pageNames[i]) {
        $(document.body).removeClass('init_' + pageNames[i]);
      }
    }

    if (page == 'done')
      return;

    var notices = [];
    $('#notice_container > *').each(function () {
      var text = $.data(this, 'notice-text');
      if (!text)
        return;
      notices.push(text);
    });
    if (notices.length) {
      $('#notice_container').empty();
      alert(notices.join("\n\n"));
    }
  },
  panicAndReload: function() {
    alert('Failed to get initial setup data from server. Cannot continue.' +
          ' Would you like to attempt to reload the web console?  This may fail if the server is not running.');
    reloadApp();
  },
  doClusterJoin: function () {
    var form = $('#init_cluster_form');

    var errorsContainer = form.parent().find('.join_cluster_dialog_errors_container');
    errorsContainer.hide();

    var data = ServersSection.validateJoinClusterParams($('.js_login-credentials'));
    if (data.length) {
      renderTemplate('join_cluster_dialog_errors', data, errorsContainer[0]);
      errorsContainer.show();
      return;
    }

    var overlay = overlayWithSpinner($('#init_cluster_dialog'), '#EEE');

    return jsonPostWithErrors('/node/controller/doJoinCluster', $.param(data), function (errors, status) {
      if (status != 'success') {
        overlay.remove();
        renderTemplate('join_cluster_dialog_errors', errors, errorsContainer[0]);
        errorsContainer.show();
        return;
      }

      DAL.performLogin(data.user, data.password, function (status) {
        overlay.remove();
        if (status == "success") {
          displayNotice('This server has been associated with the cluster and will join on the next rebalance operation.');
        } else {
          reloadApp();
        }
      });
    });
  },
  pages: {
    bucket_dialog: function (node, pagePrefix, opt) {
      var spinner;
      var timeout = setTimeout(function () {
        spinner = overlayWithSpinner(opt.previousPage);
      }, 50);

      var sampleBucketsRAMQuota = _.reduce(opt.sampleBuckets, function (memo, num) {
        return memo + num;
      }, 0);

      // postpone showing the dialog till the data for the gauge is loaded
      return function (callback) {
        prepareInitialData(function (data) {
          createBucketDialog(data, callback);
        });
      }

      function prepareInitialData(callback) {
        var data = _.extend({
          uri: '/pools/default/buckets',
          validateURL: '/pools/default/buckets?just_validate=1&ignore_warnings=1',
          bucketType: 'membase',
          authType: 'sasl',
          replicaNumber: 1,
          replicaIndex: false,
          threadsNumber: 3,
          thisIsBucketTemplate: true
        }, $.deparam(opt.defaultBucketData ? opt.defaultBucketData : ''));

        var nodesSelfCell = Cell.compute(function (v) {
          return future.get({url: "/nodes/self"});
        });

        var missingDefaultBucketMarker = {};

        var defaultBucketInfoCell = Cell.compute(function (v) {
          return future.get({
            url: "/pools/default/buckets/default",
            missingValue: missingDefaultBucketMarker
          });
        });

        Cell.compute(function (v) {
          return [v.need(nodesSelfCell), v.need(defaultBucketInfoCell)];
        }).getValue(function (arr) {
          nodeData = arr[0];
          defaultBucketInfo = arr[1];
          if (defaultBucketInfo === missingDefaultBucketMarker) {
            data = _.extend({
              quota: {
                rawRAM: nodeData.storageTotals.ram.quotaTotal - nodeData.storageTotals.ram.quotaUsed
                  - sampleBucketsRAMQuota
              }
            }, data);
          } else {
            data = defaultBucketInfo;
          }
          callback(data);
        });
      };

      function getFormValuesForValidation(form) {
        return serializeForm(form)
          + "&name=default&authType=sasl&saslPassword=&otherBucketsRamQuotaMB="
          + BytestoMB(sampleBucketsRAMQuota);
      }

      function createBucketDialog(initValue, callback) {
        var dialogVisible = false;
        var defaultBucketExists = !initValue.thisIsBucketTemplate;
        var dialog = new BucketDetailsDialog(initValue, !defaultBucketExists, {
          id: 'init_bucket_dialog',
          refreshBuckets: function (b) {
            b();
          },
          doCreateBucket: function (uri, form, callback) {
            if (defaultBucketExists) {
              opt.defaultBucketData = false;
              var data = dialog.getFormValues(form);
              jsonPostWithErrors(uri, data, callback);
              return;
            }
            opt.defaultBucketData = dialog.getFormData();
            jsonPostWithErrors(initValue.validateURL, getFormValuesForValidation(form), callback);
          },
          onSuccess: function () {
            dialog.cleanup();
            SetupWizard.show('update_notifications', opt);
          },
          formValidationCallback: function () {
            if (!dialogVisible) {
              dialogVisible = true;
              if (spinner)
                spinner.remove();
              clearTimeout(timeout);
              callback();
            }
          },
          getFormValues: getFormValuesForValidation
         });

        var cleanupBack = dialog.bindWithCleanup($('#step-init-bucket-back'), 'click', function () {
          opt.defaultBucketData = dialog.getFormData();
          dialog.cleanup();
          SetupWizard.show('sample_buckets', opt);
        });
        dialog.cleanups.push(cleanupBack);
        dialog.startForm();
      }
    },
    secure: function(node, pagePrefix, opt) {
      var parentName = '#' + pagePrefix + '_dialog';
      var parent = $(parentName);
      var warnUl = parent.find('.warn ul');
      var form = $(parentName + ' form').unbind('submit');

      $(parentName + ' div.config-bottom button#step-5-finish').unbind('click').click(function (e) {
        e.preventDefault();
        $('#init_secure_form').submit();
        $('#init_secure_form')[0].reset();
        $('#secure-password').focus();
      });
      $(parentName + ' div.config-bottom button#step-5-back').unbind('click').click(function (e) {
        e.preventDefault();
        SetupWizard.show("update_notifications", opt);
      });
      _.defer(function () {
        $(parentName).find('[name=password]')[0].focus();
      });

      function showSecureFormErrors(data) {
        parent.find('.warn li').remove();
        _.each(data, function (error) {
          var li = $('<li></li>');
          li.text(error);
          warnUl.prepend(li);
        });
      }

      form.submit(function (e) {

        e.preventDefault();

        var user = parent.find('[name=username]').val();
        var pw = parent.find('[name=password]').val();
        var vpw = $($i('secure-password-verify')).val();
        if (pw == null || pw == "") {
          showSecureFormErrors(['A password of at least six characters is required.']);
          return;
        }
        if (pw !== vpw) {
          showSecureFormErrors(['\'Password\' and \'Verify Password\' do not match.']);
          return;
        }

        var createSampleBuckets = function (sampleBuckets, onSuccess, onError) {
          var buckets = _.keys(sampleBuckets);

          if (buckets.length === 0) {
            onSuccess();
            return;
          }
          var json = JSON.stringify(buckets);

          jsonPostWithErrors('/sampleBuckets/install', json, function (simpleErrors, status, errorObject)  {
            if (status === 'success') {
              onSuccess();
            } else {
              onError(simpleErrors, errorObject);
            }
          }, {
            timeout: 140000
          });
        };

        var createDefaultBucket = function (bucketData, onSuccess, onError) {
          if (bucketData === false) {
            onSuccess();
            return;
          }
          jsonPostWithErrors('/pools/default/buckets', bucketData + "&name=default&authType=sasl&saslPassword=",
          function (simpleErrors, status, errorObject) {
            if (status === 'success') {
              onSuccess();
            } else {
              onError(simpleErrors, null);
            }
          });
        };

        var createBuckets = function (sampleBuckets, defaultBucket, onSuccess, onError) {
          createDefaultBucket(defaultBucket, function () {
            createSampleBuckets(sampleBuckets, onSuccess, onError);
          }, onError);
        };

        var saveAuthData = function (onSuccess, onError) {
          var form = $(self);

          var postData = serializeForm(form);

          jsonPostWithErrors(form.attr('action'), postData, function (data, status) {
            if (status != 'success') {
              showSecureFormErrors(data);
              $('html, body').scrollTop(0);
              onError();
            } else {
              onSuccess();
            }
          });
        }

        var self = this;
        var spinner = overlayWithSpinner('#init_secure_dialog');
        saveAuthData(function () {
          DAL.performLogin(user, pw, function () {
            createBuckets(opt.sampleBuckets, opt.defaultBucketData,
              // success
              function () {
                spinner.remove();

                SetupWizard.show('done');

                if (user != null && user != "") {
                  $('.sign-out-link').show();
                }
              },
              // error
              function (simpleErrors, errorObject) {
                spinner.remove();

                var errReason = errorObject && errorObject.reason || simpleErrors.join(' and ');
                genericDialog({
                  buttons: {ok: true},
                  header: "Failed To Create Bucket",
                  textHTML: errReason
                });
              }
            );
          });
        },
        function () {
          spinner.remove();
        });
      });
    },
    welcome: function (node, pagePrefix, opt) {
      $('#init_welcome_dialog button.next').click(function (e) {
        e.preventDefault();
        SetupWizard.show("cluster");
      });
    },
    cluster: function (node, pagePrefix, opt) {
      var dialog = $('#init_cluster_dialog');
      var resourcesObserver;

      $('#join-cluster').click(function (e) {
        $('.js_login-credentials').slideDown();
        $('.js_start_new_cluster_block').slideUp();
        $('#init_cluster_dialog_memory_errors_container').slideUp();
      });
      $('#no-join-cluster').click(function (e) {
        $('.js_start_new_cluster_block').slideDown();
        $('.js_login-credentials').slideUp();
      });

      ServersSection.notifyAboutServicesBestPractice($('.js_start_new_cluster_block'));
      ServersSection.notifyAboutServicesBestPractice($('.js_login-credentials'));

      // we return function signaling that we're not yet ready to show
      // our page of wizard (no data to display in the form), but will
      // be at one point. SetupWizard.show() will call us immediately
      // passing us it's continuation. This is partial continuation to
      // be more precise
      return function (continueShowDialog) {
        dialog.find('.quota_error_message').hide();

        $.ajax({type:'GET', url:'/nodes/self', dataType: 'json',
                success: dataCallback, error: dataCallback});

        function dataCallback(data, status) {
          if (status != 'success') {
            return SetupWizard.panicAndReload();
          }


          // we have node data and can finally display our wizard page
          // and pre-fill the form
          continueShowDialog();

          $('#step-2-next').click(onSubmit);
          dialog.find('form').submit(onSubmit);

          _.defer(function () {
            if ($('#join-cluster')[0].checked)
              $('.js_login-credentials').show();
          });

          var m = data['memoryQuota'];
          if (m == null || m == "none") {
            m = "";
          }

          dialog.find('[name=quota]').val(m);

          data['node'] = data['node'] || node;

          var hostname = dialog.find('[name=hostname]');
          hostname.val(data['otpNode'].split('@')[1] || '127.0.0.1');

          var storageTotals = data.storageTotals;

          var totalRAMMegs = Math.floor(storageTotals.ram.total/Math.Mi);

          dialog.find('[name=dynamic-ram-quota]').val(Math.floor(storageTotals.ram.quotaTotal / Math.Mi));
          dialog.find('.ram-total-size').text(totalRAMMegs + ' MB');
          var ramMaxMegs = Math.max(totalRAMMegs - 1024,
                                    Math.floor(storageTotals.ram.total * 4 / (5 * Math.Mi)));
          dialog.find('.ram-max-size').text(ramMaxMegs);

          var firstResource = data.storage.hdd[0];

          var dbPath;
          var dbTotal;

          var ixPath;
          var ixTotal;

          dbPath = dialog.find('[name=db_path]');
          ixPath = dialog.find('[name=index_path]');

          dbTotal = dialog.find('.total-db-size');
          ixTotal = dialog.find('.total-index-size');

          dbPath.val(firstResource.path);
          ixPath.val(firstResource.index_path);

          var hddResources = data.availableStorage.hdd;
          var mountPoints = new MountPoints(data, _.pluck(hddResources, 'path'));

          var prevPathValues = {};

          maybeUpdateTotal(dbPath, dbTotal);
          maybeUpdateTotal(ixPath, ixTotal);

          resourcesObserver = dialog.observePotentialChanges(
            function () {
              maybeUpdateTotal(dbPath, dbTotal);
              maybeUpdateTotal(ixPath, ixTotal);
            });

          return;

          function updateTotal(node, total) {
            node.text(escapeHTML(total) + ' GB');
          }

          function maybeUpdateTotal(pathNode, totalNode) {
            var pathValue = pathNode.val();

            if (pathValue == prevPathValues[pathNode.selector]) {
              return;
            }

            prevPathValues[pathNode] = pathValue;
            if (pathValue == "") {
              updateTotal(totalNode, 0);
              return;
            }

            var rv = mountPoints.lookup(pathValue);
            var pathResource = ((rv != null) && hddResources[rv]);

            if (!pathResource) {
              pathResource = {path:"/", sizeKBytes: 0, usagePercent: 0};
            }

            var totalGigs =
              Math.floor(pathResource.sizeKBytes *
                         (100 - pathResource.usagePercent) / 100 / Math.Mi);
            updateTotal(totalNode, totalGigs);
          }
        }
      }

      // cleans up all event handles
      function onLeave() {
        $('#step-2-next').unbind();
        dialog.find('form').unbind();
        if (resourcesObserver)
          resourcesObserver.stopObserving();
      }

      var saving = false;

      function onSubmit(e) {
        e.preventDefault();
        if (saving) {
          return;
        }
        saving = true;

        dialog.find('.warning').hide();

        var dbPath = dialog.find('[name=db_path]').val();
        var ixPath = dialog.find('[name=index_path]').val();
        var hostname = dialog.find('[name=hostname]').val();
        var memoryQuota  = dialog.find('[name=dynamic-ram-quota]').val() || "none";
        var services = ServersSection.getCheckedServices($('.js_start_new_cluster_block'));

        var pathErrorsContainer = dialog.find('.init_cluster_dialog_errors_container');
        var hostnameErrorsContainer = $('#init_cluster_dialog_hostname_errors_container');
        var memoryErrorsContainer = $('#init_cluster_dialog_memory_errors_container');
        var serviceErrorsContainer = $('#init_cluster_service_errors_container');
        $(pathErrorsContainer, hostnameErrorsContainer, memoryErrorsContainer, serviceErrorsContainer).hide();

        var spinner = overlayWithSpinner(dialog);

        var diskParams = $.param({path: dbPath, index_path: ixPath});
        var hostnameParams = $.param({hostname: hostname});
        var memoryQuotaParams = $.param({memoryQuota: memoryQuota});
        var servicesParams = $.param({services: services});
        var ajaxOptions = {dataType: 'text'}; //because with dataType json jQuery returning “parsererror”

        jQuery.when(
          jsonPostWithErrors('/nodes/' + node + '/controller/settings', diskParams, maybeShowDiskErrors, ajaxOptions),
          jsonPostWithErrors('/node/controller/rename', hostnameParams, maybeShowHostnameErrors, ajaxOptions)
        ).done(function () {
          if ($('#no-join-cluster')[0].checked) {
            jQuery.when(
              jsonPostWithErrors("/node/controller/setupServices", servicesParams, maybeShowServicesErrors, ajaxOptions),
              jsonPostWithErrors('/pools/default', memoryQuotaParams, maybeShowMemoryQuotaErrors, ajaxOptions)
            ).done(function () {
              BucketsSection.refreshBuckets();
              SetupWizard.show("sample_buckets");
              onLeave();
            }).always(removeSpinner);
          } else {
            var deferred = SetupWizard.doClusterJoin();
            if (deferred) {
              deferred.always(removeSpinner);
            } else {
              removeSpinner();
            }
          }
        }).fail(removeSpinner);

        function removeSpinner() {
          saving = false;
          spinner.remove();
        }

        function maybeShowDiskErrors(data, status, errObject) {
          if (status !== 'success') {
            renderTemplate('join_cluster_dialog_errors', errObject, pathErrorsContainer[0]);
            pathErrorsContainer.show();
          }
        }

        function maybeShowMemoryQuotaErrors(data, status, errObject) {
          if (status !== 'success') {
            memoryErrorsContainer.text(errObject.errors.memoryQuota);
            memoryErrorsContainer.show();
          }
        }

        function maybeShowServicesErrors(data, status, errObject) {
          if (status !== 'success') {
            serviceErrorsContainer.text(errObject.error);
            serviceErrorsContainer.show();
          }
        }

        function maybeShowHostnameErrors(data, status, errObject) {
          if (status !== 'success') {
            hostnameErrorsContainer.text(errObject[0]);
            hostnameErrorsContainer.show();
          }
        }
      }
    },
    update_notifications: function(node, pagePrefix, opt) {
      var dialog = $('#init_update_notifications_dialog');
      var emailField = $('#init-join-community-email').need(1);
      var formObserver;

      $('#update_notifications_errors_container').hide();

      dialog.find('button.back').unbind('click').click(function (e) {
        e.preventDefault();
        onLeave();
        SetupWizard.show("bucket_dialog", _.extend(opt, {previousPage: '#init_update_notifications_dialog'}));
      });

      dialog.find('button.next').unbind('click').click(onNext);
      dialog.find('form').unbind('submit').bind('submit', function (e) {
        e.preventDefault();
        dialog.find('button.next').trigger('click');
      });

      formObserver = dialog.observePotentialChanges(emailFieldValidator);

      var appliedValidness = {};
      function applyValidness(validness) {
        _.each(validness, function (v, k) {
          if (appliedValidness[k] === v) {
            return;
          }
          $($i(k))[v ? 'addClass' : 'removeClass']('invalid');
          appliedValidness[k] = v;
        });
      }

      var emailValue;
      var emailInvalidness;

      function validateEmailField() {
        var newEmailValue = $.trim(emailField.val());
        if (emailValue !== newEmailValue) {
          emailValue = newEmailValue;
          emailInvalidness = (newEmailValue !== '' && !HTML5_EMAIL_RE.exec(newEmailValue));
        }
        return emailInvalidness;
      }

      var invalidness = {};
      function emailFieldValidator() {
        var emailId = emailField.attr('id');
        invalidness[emailId] = validateEmailField();
        applyValidness(invalidness);
      }

      var sending;

      // Go to next page. Send off email address if given and apply settings
      function onNext(e) {
        e.preventDefault();
        if (sending) {
          // this prevents double send caused by submitting form via
          // hitting Enter
          return;
        }
        $('#update_notifications_errors_container').hide();

        var errors = [];
        var formObserverResult;

        if (formObserver) {
          formObserver.callback() || {};
        }

        if (emailInvalidness) {
          errors.push("Email appears to be invalid");
        }

        if (DAL.cells.isEnterpriseCell.value) {
          var termsChecked = !!$('#init-join-terms').attr('checked');
          if (!termsChecked) {
            errors.push("Terms and conditions need to be accepted in order to continue");
          }
        }

        if (errors.length) {
          var invalidFields = dialog.find('.invalid');
          renderTemplate('update_notifications_errors', errors);
          $('#update_notifications_errors_container').show();
          if (invalidFields.length && !_.include(invalidFields, document.activeElement)) {
            setTimeout(function () {try {invalidFields[0].focus();} catch (e) {}}, 10);
          }
          return;
        }

        var email = $.trim(emailField.val());
        if (email!=='') {
          // Send email address. We don't care if notifications were enabled
          // or not.
          $.ajax({
            url: UpdatesNotificationsSection.remote.email,
            dataType: 'jsonp',
            data: {email: email,
                   firstname: $.trim($('#init-join-community-firstname').val()),
                   lastname: $.trim($('#init-join-community-lastname').val()),
                   company: $.trim($('#init-join-community-company').val()),
                   version: DAL.version || "unknown"},
            success: function () {},
            error: function () {}
          });
        }

        var sendStatus = $('#init-notifications-updates-enabled').is(':checked');
        sending = true;
        var spinner = overlayWithSpinner(dialog);
        jsonPostWithErrors(
          '/settings/stats',
          $.param({sendStats: sendStatus}),
          function () {
            spinner.remove();
            sending = false;
            onLeave();
            SetupWizard.show("secure", opt);
          }
        );
      }

      // cleans up all event handles
      function onLeave() {
        if (formObserver) {
          formObserver.stopObserving();
        }
      }
    },

    sample_buckets: function(node, pagePrefix, opt) {

      var spinner;
      var timeout = setTimeout(function() {
        spinner = overlayWithSpinner($('#init_sample_buckets_dialog'), '#EEE');
      }, 20);

      var dialog = $('#init_sample_buckets_dialog');
      var back = dialog.find('button.back');
      var next = dialog.find('button.next');

      var sampleBucketsQuota = {};

      _.defer(function () {
        try {next[0].focus();} catch (e) {}
      });

      function checkedBuckets() {
        return _.map(dialog.find(':checked'), function(obj) {
          return $(obj).val();
        });
      }

      function enableForm() {
        dialog.add(next).add(back).css('cursor', 'auto').attr('disabled', false);
      }

      back.unbind('click').click(function (e) {
        e.preventDefault();
        SetupWizard.show('cluster');
      });

      next.unbind('click').click(function (e) {

        e.preventDefault();
        dialog.add(next).add(back).css('cursor', 'wait').attr('disabled', true);

        var buckets = checkedBuckets();

        opt.sampleBuckets = {};
        _.each(buckets, function (name) {
          opt.sampleBuckets[name] = sampleBucketsQuota[name];
        });

        enableForm();
        SetupWizard.show("bucket_dialog", _.extend(opt, {previousPage: '#init_sample_buckets_dialog'}));
      });

      $.get('/sampleBuckets', function (buckets) {
        var tmp, htmlName, available = [];
        _.each(buckets, function (bucket) {
          htmlName = escapeHTML(bucket.name);
          if (!bucket.installed) {
            sampleBucketsQuota[bucket.name] = bucket.quotaNeeded;
            var checkedAttr = "";
            if (opt != undefined && opt.sampleBuckets != undefined && (bucket.name in opt.sampleBuckets)) {
               checkedAttr = " checked='checked'";
            }
            tmp = '<li><input type="checkbox" value="' + htmlName +
              '" id="setup-sample-' + htmlName + '"' + checkedAttr + ' /> ' +
              '<label for="setup-sample-' + htmlName + '">' +
              htmlName + '</label></li>';
            available.push(tmp);
          }
        });

        available = (available.length === 0) ?
          '<li>There are no samples available to install.</li>' :
          available.join('');

        $('#setup_available_samples').html(available);

        enableForm();

        clearTimeout(timeout);
        if (spinner) {
          spinner.remove();
        }
      });

    }
  }
};

$(function () {
  $(document.body).removeClass('nojs');

  _.defer(function () {
    var e = $('#auth_dialog [name=login]').get(0);
    try {e.focus();} catch (ex) {}
  });

  $('#login_form').bind('submit', function (e) {
    e.preventDefault();
    loginFormSubmit();
  });

  if ($.cookie('rf')) {
    displayNotice('An error was encountered when requesting data from the server.  ' +
                  'The console has been reloaded to attempt to recover.  There ' +
                  'may be additional information about the error in the log.');
    DAL.onReady(function () {
      $.cookie('rf', null);
      if ('sessionStorage' in window && window.sessionStorage.reloadCause) {
        var text = "Browser client XHR failure encountered. (age: "
          + ((new Date()).valueOf() - sessionStorage.reloadTStamp)+")  Diagnostic info:\n";
        postClientErrorReport(text + window.sessionStorage.reloadCause);
        delete window.sessionStorage.reloadCause;
        delete window.sessionStorage.reloadTStamp;
      }
    });
  }

  ThePage.initialize();

  DAL.onReady(function () {
    $(window).trigger('hashchange');
  });

  function removeAuthDialogSpinner() {
    try {
      $('#auth_dialog .spinner').remove();
    }
    catch (__ignore) {}
  }

  function initCellValuesBeforeRendering(callback) {
    DAL.cells.poolList.getValue(function (poolList) {
      if (poolList.length == 0) {
        /* if the cluster is not provisioned the cell values
        are not going to be calculated */
        callback();
        return;
      }

      /*
      this cell has to be loaded before rendering of the screen
      to make sure that elements with classes 'only-when-20' and 'only-when-below-20'
      are properly shown/hidden which prevents higly visible blinking of the tabs
      during reload
      */
      DAL.cells.runningInCompatMode.getValue(function (_value) {
        callback();
      });
    });
  }

  try {
    if (DAL.tryNoAuthLogin()) {
      initCellValuesBeforeRendering(function () {
        hideAuthForm();
        removeAuthDialogSpinner();
      });
    } else {
      removeAuthDialogSpinner();
    }
  } catch (_ignore) {
    removeAuthDialogSpinner();
  }

  if (!DAL.login && $('#login_form:visible').length) {
    var backdoor =
      (function () {
        var href = window.location.href;
        var match = /\?(.*?)(?:$|#)/.exec(href);
        var rv = false;
        if (match && /(&|^)na(&|$)/.exec(match[1]))
          rv = true;
        return rv;
      })();
    if (backdoor) {
      var login = $('#login_form [name=login]').val('Administrator');
      var password = $('#login_form [name=password]').val('asdasd');
      loginFormSubmit();
    }
  }
});

function showAbout() {
  doShowAbout();
}

function doShowAbout(certAsGiven) {
  function updateVersion() {
    var components = DAL.componentsVersion;
    if (components)
      $('#about_versions').text("Version: " + DAL.prettyVersion(components['ns_server']));
    else {
      $.get('/versions', function (data) {
        DAL.componentsVersion = data.componentsVersion;
        updateVersion();
      }, 'json')
    }

    var poolDetails = DAL.cells.currentPoolDetailsCell.value || {nodes:[]};
    var nodesCount = poolDetails.nodes.length;
    if (nodesCount >= 0x100)
      nodesCount = 0xff;

    var buckets = DAL.cells.bucketsListCell.value;
    if (buckets !== undefined) {
      var bucketsCount = buckets.length;
      if (bucketsCount >= 100)
        bucketsCount = 99;

      var memcachedBucketsCount = buckets.byType.memcached.length;
      var membaseBucketsCount = buckets.byType.membase.length;

      if (memcachedBucketsCount >= 0x10)
        memcachedBucketsCount = 0xf;
      if (membaseBucketsCount >= 0x10)
        membaseBucketsCount = 0x0f;

      var date = (new Date());

      var magicString = [
        integerToString(0x100 + poolDetails.nodes.length, 16).slice(1)
          + integerToString(date.getMonth()+1, 16),
        integerToString(100 + bucketsCount, 10).slice(1)
          + integerToString(memcachedBucketsCount, 16),
        integerToString(membaseBucketsCount, 16)
          + date.getDate()
      ];
      $($i('cluster_state_id')).text(magicString.join('-'));
    } else {
      $($i('cluster_state_id')).html('Please login to view your ' +
          'Cluster State ID.');
    }
  }
  updateVersion();
  showDialog('about_server_dialog',
      {title: $('#about_server_dialog .config-top').hide().html()});
}

function displayNotice(text, isError) {
  var div = $('<div></div>');
  var tname = 'notice';
  if (isError || (isError === undefined && text.indexOf('error') >= 0)) {
    tname = 'noticeErr';
  }
  renderTemplate(tname, {text: text}, div.get(0));
  $.data(div.children()[0], 'notice-text', text);
  $('#notice_container').prepend(div.children());
  ThePage.gotoSection("overview");
}

$('.notice').live('click', function () {
  var self = this;
  $(self).fadeOut('fast', function () {
    $(self).remove();
  });
});

$('.tooltip').live('click', function (e) {
  e.preventDefault();
  $('.tooltip_msg', this).stop(true, true).fadeIn();
}).live('mouseleave', function (e) {
  $('.tooltip_msg', this).stop(true, true).fadeOut();
})
.delegate('.tooltip_msg', 'mouseenter', function (e) {
  $(this).stop(true, true).fadeIn(0);
});

configureActionHashParam('visitSec', function (sec) {
  ThePage.gotoSection(sec);
});

$(function () {
  var container = $('.io-error-notice');
  var timeoutId;
  function renderStatus() {
    if (timeoutId != null) {
      clearTimeout(timeoutId);
      timeoutId = null;
    }

    var status = IOCenter.status.value;

    if (status.healthy) {
      container.hide();
      return;
    }

    container.show();

    if (status.repeating) {
      container.text('Repeating failed XHR request...');
      return
    }

    var now = (new Date()).getTime();
    var repeatIn = Math.max(0, Math.floor((status.repeatAt - now)/1000));
    container.html('Lost connection to server at ' + window.location.host + '. Repeating in ' + repeatIn + ' seconds. <a href="#">Retry now</a>');
    var delay = Math.max(200, status.repeatAt - repeatIn*1000 - now);
    timeoutId = setTimeout(renderStatus, delay);
  }

  container.find('a').live('click', function (e) {
    e.preventDefault();
    IOCenter.forceRepeat();
  });

  IOCenter.status.subscribeValue(renderStatus);
});

$(function () {
  if (!('AllImages' in window))
    return;
  var images = window['AllImages']

  var body = $(document.body);
  _.each(images, function (path) {
    var j = $(new Image());
    j[0].src = path;
    j.css('display', 'none');
    j.appendTo(body);
  });
});


function runInternalSettingsDialog() {
  var dialog = $('#internal_settings_dialog');
  var form = dialog.find("form");
  showDialog(dialog, {
    title: 'Tweak internal settings',
    onHide: onHide
  });

  var cleanups = [];
  var firedSubmit = false;
  var spinner;
  setTimeout(start, 10);
  return;

  function start() {
    spinner = overlayWithSpinner(form);
    $.getJSON("/internalSettings", populateForm);
  }

  function populateForm(data) {
    setFormValues(form, data);
    spinner.remove();
    var undoBind = BucketDetailsDialog.prototype.bindWithCleanup(form, "submit", onSubmit);
    cleanups.push(undoBind);
  }

  function onSubmit(ev) {
    ev.preventDefault();
    if (firedSubmit) {
      return;
    }
    firedSubmit = true;
    var data = serializeForm(form);
    var secondSpinner = overlayWithSpinner(dialog, undefined, "Saving...");
    $.post('/internalSettings', data, submittedOk);
    cleanups.push(function () {
      secondSpinner.remove();
    });
  }

  function submittedOk() {
    hideDialog(dialog);
  }

  function onHide() {
    _.each(cleanups, function (c) {c()});
  }
}


function initAlertsCells(ns, poolDetailsCell) {
  ns.rawAlertsCell = Cell.compute(function (v) {
    return v.need(poolDetailsCell).alerts;
  }).name("rawAlertsCell");
  ns.rawAlertsCell.equality = _.isEqual;

  // this cells adds timestamps to each alert message each message is
  // added timestamp when it was first seen. With assumption that
  // alert messages are added to the end of alerts array
  //
  // You can see that implementation is using it's own past result if
  // past messages array are prefix of current messages array to
  // achieve this behavior.
  //
  // Also note that undefined rawAlertsCell leads this cell to
  // preserve it's past value. So that poolDetailsCell recomputations
  // do not 'reset history'
  ns.stampedAlertsCell = Cell.compute(function (v) {
    var oldStampedAlerts = this.self.value || [];
    var newRawAlerts = v(ns.rawAlertsCell);
    if (!newRawAlerts) {
      return oldStampedAlerts;
    }
    var i;
    if (oldStampedAlerts.length > newRawAlerts.length) {
      oldStampedAlerts = [];
    }
    for (i = 0; i < oldStampedAlerts.length; i++) {
      if (oldStampedAlerts[i][1] != newRawAlerts[i]) {
        break;
      }
    }
    var rv = (i == oldStampedAlerts.length) ? _.clone(oldStampedAlerts) : [];
    _.each(newRawAlerts.slice(rv.length), function (msg) {
      rv.push([new Date(), msg]);
    });
    return rv;
  }).name("stampedAlertsCell");
  ns.stampedAlertsCell.equality = _.isEqual;

  ns.alertsAndSilenceURLCell = Cell.compute(function (v) {
    return {
      stampedAlerts: v.need(ns.stampedAlertsCell),
      alertsSilenceURL: v.need(poolDetailsCell).alertsSilenceURL
    };
  }).name("alertsAndSilenceURLCell");
  ns.alertsAndSilenceURLCell.equality = _.isEqual;
}


// uses /pools/default to piggyback any user alerts we want to show
function initAlertsSubscriber() {
  var visibleDialog;

  var cells = {};
  window.alertsCells = cells;
  initAlertsCells(cells, DAL.cells.currentPoolDetailsCell);

  cells.alertsAndSilenceURLCell.subscribeValue(function (alertsAndSilenceURL) {
    if (!alertsAndSilenceURL) {
      return;
    }
    if (alertsAreDisabled) {
      return;
    }
    var alerts = alertsAndSilenceURL.stampedAlerts;
    var alertsSilenceURL = alertsAndSilenceURL.alertsSilenceURL;
    if (!alerts.length) {
      return;
    }

    if (visibleDialog) {
      visibleDialog.close();
    }


    var alertsMsg = _.map(alerts, function (alertItem) {
      var tstamp = "<strong>["+escapeHTML(formatTime(alertItem[0]))+"]</strong>";
      return tstamp + " - " + escapeHTML(alertItem[1]);
    }).join("<br />");

    _.defer(function () {
      // looks like we cannot reuse dialog immediately if it was
      // closed via visibleDialog.close, thus deferring a bit
      visibleDialog = genericDialog({
        buttons: {ok: true},
        header: "Alert",
        textHTML: alertsMsg,
        dontCloseOnHashchange: true,
        callback: function (e, btn, thisDialog) {
          thisDialog.close();
          if (thisDialog !== visibleDialog) {
            BUG("thisDialog != visibleDialog");
          }
          visibleDialog = null;
          DAL.cells.currentPoolDetailsCell.setValue(undefined);
          $.ajax({url: alertsSilenceURL,
                  type: 'POST',
                  data: '',
                  timeout: 5000,
                  success: done,
                  // we don't care about errors on this request
                  error: done});
          function done() {
            DAL.cells.currentPoolDetailsCell.invalidate();
          }
        }
      });
    });
  });
};

// setup handling of .disable-if-stale class
(function () {
  function moveAttr(e, fromAttr, toAttr) {
    var toVal = e.getAttribute(toAttr);
    if (!toVal) {
      return;
    }
    var value = e.getAttribute(fromAttr);
    if (!value) {
      return;
    }
    e.removeAttribute(fromAttr);
    e.setAttribute(toAttr, value);
  }
  function processLinks() {
    var enable = !IOCenter.staleness.value;
    $(document.body)[enable ? 'removeClass' : 'addClass']('staleness-active');
    if (enable) {
      $('a.disable-if-stale').each(function (i, e) {
        moveAttr(e, 'disabled-href', 'href');
      });
    } else {
      $('a.disable-if-stale').each(function (i, e) {
        moveAttr(e, 'href', 'disabled-href');
      });
    }
  }
  IOCenter.staleness.subscribeValue(processLinks);
  $(window).bind('template:rendered', processLinks);
})();

var alertsAreDisabled = false;

$(function () {
  var href = window.location.href;
  var match = /\?(.*?)(?:$|#)/.exec(href);
  if (!match)
    return;
  var params = deserializeQueryString(match[1]);
  if (params['enableInternalSettings']) {
    $('#edit-internal-settings-link').show();
  }
  if (params['disablePoorMansAlerts']) {
    alertsAreDisabled = true;
  }
});

(function () {
  var lastCompatVersion;

  DAL.cells.compatVersion.subscribeValue(function (value) {
    if (value === undefined) {
      return;
    }
    lastCompatVersion = value;
    updateVisibleStuff();
  });

  function updateVisibleStuff() {
    var version25 = encodeCompatVersion(2, 5);
    var version30 = encodeCompatVersion(3, 0);
    var version32 = encodeCompatVersion(3, 2);

    $('body').toggleClass('dynamic_under-25', lastCompatVersion < version25);
    $('body').toggleClass('dynamic_under-30', lastCompatVersion < version30);
    $('body').toggleClass('dynamic_under-32', lastCompatVersion < version32);
  }


  $(window).bind('template:rendered', function () {
    if (lastCompatVersion !== undefined) {
      updateVisibleStuff();
    }
  });
})();
