(function () {
  "use strict";

  angular
    .module('mnGroups', [
      'mnGroupsService',
      'mnSpinner',
      'mnHelper',
      'mnPoll',
      'mnPromiseHelper',
      'mnDragAndDrop',
      'ui.bootstrap',
      'mnFilters',
      'mnAlertsService',
      'mnPoolDefault'
    ])
    .controller('mnGroupsController', mnGroupsController);

    function mnGroupsController($scope, $uibModal, mnGroupsService, mnPromiseHelper, mnHelper, mnPoller, jQuery, mnMakeSafeForCSSFilter, mnNaturalSortingFilter, $window, mnAlertsService, mnPoolDefault) {
      var vm = this;

      vm.createGroup = createGroup;
      vm.deleteGroup = deleteGroup;
      vm.applyChanges = applyChanges;
      vm.reloadState = mnHelper.reloadState;

      vm.onItemTaken = onItemTaken;
      vm.onItemDropped = onItemDropped;
      vm.onItemMoved = onItemMoved;

      vm.disableApplyChangesBtn = true;

      activate();

      function applyChanges() {
        mnPromiseHelper($scope, mnGroupsService.applyChanges(vm.state.uri, vm.state.currentGroups))
          .reloadState()
          .getPromise()
          .then(null, function (resp) {
            if (resp.status === 409) {
              vm.disableAddGroupBtn = true;
              vm.disableApplyChangesBtn = true;
              vm.revisionMismatch = true;
            } else {
              mnAlertsService.showAlertInPopup(resp.data, 'error', timeout);
            }
          });
      }

      function deleteGroup(group) {
        var initialGroups = vm.state.initialGroups;
        var currentGroups = vm.state.currentGroups;

        if (_.isEqual(initialGroups, currentGroups)) {
          return $uibModal.open({
            templateUrl: 'app/mn_admin/mn_groups/delete_dialog/mn_groups_delete_dialog.html',
            controller: 'mnGroupsDeleteDialogController as groupsDeleteDialogCtl',
            resolve: {
              group: mnHelper.wrapInFunction(group)
            }
          });
        } else {
          $window.scrollTo(0, 0);
          vm.serverGroupsWarnig = true;
          vm.disableApplyChangesBtn = false;
        }
      }

      function createGroup(group) {
        return $uibModal.open({
          templateUrl: 'app/mn_admin/mn_groups/group_dialog/mn_groups_group_dialog.html',
          controller: 'mnGroupsGroupDialogController as groupsGroupDialogCtl',
          resolve: {
            group: mnHelper.wrapInFunction(group)
          }
        });
      }

      function activate() {
        mnPromiseHelper(vm, mnGroupsService.getGroupsState())
          .applyToScope("state")
          ;
        //after implementing mmAdminController via controllerAs syntax this poll should be removed
        new mnPoller($scope, function () {
          return mnPoolDefault.get();
        })
          .subscribe(function (poolDefault) {
            vm.rebalancing = poolDefault.rebalancing;
          })
          .cycle();
      }


      //this part of code should be reworked in angular style later
      //or we can use something like https://github.com/marceljuenemann/angular-drag-and-drop-lists
      var dragSelector = ".js_draggable";
      var overSelector = ".js_group_wrapper";
      var putIntoSelector = ".js_group_servers";
      var overActiveSelector = "dynamic_over";
      var emplyListSelector = "dynamic_empty";
      var contextSelector = "#js_groups";
      var placeholderSelector = "js_drag_placeholder drag_placeholder";
      var placeholder = jQuery("<span />").addClass(placeholderSelector).get(0);
      var prevRecipientGroupDomElement;
      var jQApplicantDomElements;
      var takenDomElement;
      var takenGroupDomElement;
      var recipientDomElement;
      var hostnameComparator = mkComparatorByProp('hostname', mnNaturalSortingFilter);

      function onItemTaken(serverHostname) {
        jQApplicantDomElements = jQuery(overSelector, contextSelector);
        takenDomElement = jQuery(dragSelector + "_" + mnMakeSafeForCSSFilter(serverHostname));
        takenGroupDomElement = detectAcceptingTarget(jQApplicantDomElements, takenDomElement);

        jQuery(takenDomElement).after(placeholder);
        jQuery(takenGroupDomElement).addClass(overActiveSelector);
      }
      function onItemDropped() {
        recipientDomElement = detectAcceptingTarget(jQApplicantDomElements, takenDomElement) || prevRecipientGroupDomElement;

        jQuery(placeholder).detach();
        jQuery(takenDomElement).css({left: "", top: ""});
        jQApplicantDomElements.removeClass(overActiveSelector);

        if (recipientDomElement === takenGroupDomElement) {
          return;
        }

        var takenDomElementIndex = jQuery(takenDomElement).index();

        var currentGroups = vm.state.currentGroups;
        var takenFromGroup = currentGroups[jQuery(takenGroupDomElement).index()].nodes;
        var takenServer = takenFromGroup[takenDomElementIndex];
        var recipientGroup = currentGroups[jQuery(recipientDomElement).index()].nodes;

        recipientGroup.push(takenServer);
        recipientGroup.sort(hostnameComparator);

        var indexInRecipientGroup = arrayObjectIndexOf(recipientGroup, takenServer.hostname, "hostname");
        insertAt(jQuery(recipientDomElement).find(putIntoSelector), takenDomElement, indexInRecipientGroup);

        takenFromGroup.splice(takenDomElementIndex, 1);


        vm.disableApplyChangesBtn = _.isEqual(currentGroups, vm.state.initialGroups);
        vm.disableAddGroupBtn = false;
        vm.serverGroupsWarnig = false;
        $scope.$apply();

        takenGroupDomElement = undefined;
        takenDomElement = undefined;
      }
      function onItemMoved() {
        if (!takenDomElement) {
          return;
        }

        recipientDomElement = detectAcceptingTarget(jQApplicantDomElements, takenDomElement) || prevRecipientGroupDomElement;
        var recipientGroupIsChanged = prevRecipientGroupDomElement && recipientDomElement !== prevRecipientGroupDomElement;

        if (recipientGroupIsChanged) {
          jQuery(prevRecipientGroupDomElement).removeClass(overActiveSelector);
        }

        jQuery(recipientDomElement).addClass(overActiveSelector);

        if (takenGroupDomElement === recipientDomElement) {
          jQuery(takenDomElement).after(placeholder);
        } else {
          var currentGroups = vm.state.currentGroups;
          var takenFromGroup = currentGroups[jQuery(takenGroupDomElement).index()].nodes;
          var takenServer = takenFromGroup[jQuery(takenDomElement).index()];
          var recipientGroup = _.cloneDeep(currentGroups[jQuery(recipientDomElement).index()].nodes);

          recipientGroup.push(takenServer);
          recipientGroup.sort(hostnameComparator);

          var indexInRecipientGroup = arrayObjectIndexOf(recipientGroup, takenServer.hostname, "hostname");
          insertAt(jQuery(recipientDomElement).find(putIntoSelector), placeholder, indexInRecipientGroup);
        }

        prevRecipientGroupDomElement = recipientDomElement;
      }

      function insertAt(node, elements, index) {
        var array = jQuery.makeArray(node.children());
        array.splice(index, 0, elements);
        node.append(array);
        return this;
      }

      function fullOffset(node) {
        var offset = jQuery(node).offset();
        offset.bottom = offset.top + jQuery(node).outerHeight();
        offset.right = offset.left + jQuery(node).outerWidth();
        return offset;
      }

      function arrayObjectIndexOf(array, searchTerm, property) {
        var i;
        var length = array.length;
        for (i = 0; i < length; i++) {
          if (array[i][property] === searchTerm) {
            return i;
          }
        }
      }

      function mkComparatorByProp(propName, propComparator) {
        propComparator = propComparator || defaultComparator;
        return function (a,b) {
          return propComparator(a[propName], b[propName]);
        }
      }

      function detectAcceptingTarget(jQApplicantsList, node) {
        var nodeOffset = fullOffset(node);

        return (_.chain(jQApplicantsList).map(function (applicant) {
          var applicantOffset = fullOffset(applicant);
          return {
            self: applicant,
            sideA: Math.min(nodeOffset.right, applicantOffset.right) - Math.max(nodeOffset.left, applicantOffset.left),
            sideB: Math.min(nodeOffset.bottom, applicantOffset.bottom) - Math.max(nodeOffset.top, applicantOffset.top)
          }
        }).filter(function (elementC) {
          return elementC.sideA > 0 && elementC.sideB > 0;
        }).max(function (elementC) {
          return elementC.sideA  * elementC.sideB;
        }).value() || {}).self;
      }
    }

})();