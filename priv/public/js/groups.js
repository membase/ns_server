function makeServerGroupsCells(ns) {
  ns.groupsCell = Cell.compute(function (v) {
    if (v.need(DAL.cells.mode) != "groups") {
      return;
    }
    // note: we capture _snapshot_ of groups cell, thus no dependency
    // and we do future thing to actually make sure we capture it when
    // it's ready and not just grab whatever current value is
    return future(function (callback) {
      DAL.cells.groupsUpdatedByRevisionCell.getValue(function (val) {
        callback(val);
      });
    });
  }).name("groupsCell");

  (function (origInvalidate) {
    ns.groupsCell.invalidate = function () {
      // we invalidate groupsUpdatedByRevisionCell first because
      // otherwise we would simply replace "snapshot" and that would
      // be old value
      DAL.cells.groupsUpdatedByRevisionCell.invalidate();
      origInvalidate.call(ns.groupsCell);
    }
  })(ns.groupsCell.invalidate);
}

var sortableServerGroups = {
  initialize: function (config) {
    var self = this;
    self.groups = $.extend(true, {}, config.groups);
    var placeholder = $("<span />").addClass(config.placeholderSelector).get(0);
    var jQApplicantDomElements = $(config.overSelector, config.contextSelector);
    var recipientDomElement;
    var prevRecipientGroupDomElement;
    var takenGroupDomElement;
    var takenDomElement;

    dragDropWidget.makeDraggable({
      contextSelector: config.contextSelector,
      elementSelector: config.dragSelector,
      onItemTaken: function () {
        takenDomElement = this.draggedObject;
        takenGroupDomElement = detectAcceptingTarget(jQApplicantDomElements, takenDomElement);

        $(takenDomElement).after(placeholder);
        $(takenGroupDomElement).addClass(config.overActiveSelector);
      },
      onItemDropped: function () {
        recipientDomElement = detectAcceptingTarget(jQApplicantDomElements, takenDomElement) || prevRecipientGroupDomElement;

        $(placeholder).detach();
        $(takenDomElement).css({left: "", top: ""});
        jQApplicantDomElements.removeClass(config.overActiveSelector);

        if (recipientDomElement === takenGroupDomElement) {
          return;
        }

        var takenDomElementIndex = $(takenDomElement).index();

        var takenFromGroup = self.groups.groups[$(takenGroupDomElement).index()].nodes;
        var takenServer = takenFromGroup[takenDomElementIndex];
        var recipientGroup = self.groups.groups[$(recipientDomElement).index()].nodes;

        recipientGroup.push(takenServer);
        recipientGroup.sort(config.hostNameComparator);

        var indexInRecipientGroup = arrayObjectIndexOf(recipientGroup, takenServer.hostname, "hostname");
        $(recipientDomElement).find(config.putIntoSelector).insertAt(takenDomElement, indexInRecipientGroup);

        takenFromGroup.splice(takenDomElementIndex, 1);
        if (config.onChange) {
          config.onChange();
        }

        takenGroupDomElement = undefined;
      },
      onItemMoved: _.throttle(function () {
        if (!this.draggedObject) {
          return;
        }

        recipientDomElement = detectAcceptingTarget(jQApplicantDomElements, takenDomElement) || prevRecipientGroupDomElement;
        var recipientGroupIsChanged = prevRecipientGroupDomElement && recipientDomElement !== prevRecipientGroupDomElement;

        if (recipientGroupIsChanged) {
          $(prevRecipientGroupDomElement).removeClass(config.overActiveSelector);
        }

        $(recipientDomElement).addClass(config.overActiveSelector);

        if (takenGroupDomElement === recipientDomElement) {
          $(takenDomElement).after(placeholder);
        } else {
          var takenFromGroup = self.groups.groups[$(takenGroupDomElement).index()].nodes;
          var takenServer = takenFromGroup[$(takenDomElement).index()];
          var recipientGroup = _.clone(self.groups.groups[$(recipientDomElement).index()].nodes);

          recipientGroup.push(takenServer);
          recipientGroup.sort(config.hostNameComparator);

          var indexInRecipientGroup = arrayObjectIndexOf(recipientGroup, takenServer.hostname, "hostname");
          $(recipientDomElement).find(config.putIntoSelector).insertAt(placeholder, indexInRecipientGroup);
        }

        prevRecipientGroupDomElement = recipientDomElement;
      }, 25)
    });
  }
};

var ServerGroupsSection = {
  onEnter: function () {
    $("#js_groups").toggle(!!DAL.cells.isEnterpriseCell.value);
  },
  onLeave: function () {
  },
  init: function () {
    var self = this;
    var noticeContainer = $("#js_group_notice");
    var groupsContainer = $("#js_groups");
    var groupsListContainer = $("#js_server_group_container");
    var addGroupBtn = $('#js_create_group', groupsContainer);
    var saveChngesBtn = $('#js_save_groups_changes', groupsContainer);
    var hostNameComparator = mkComparatorByProp('hostname', naturalSort);
    var nameComparator = mkComparatorByProp('name', naturalSort);
    var addGroupDialog = $("#js_add_group_dialog");
    var addGroupError = $(".js_error_group", addGroupDialog);
    var addGroupsForm = $("#js_add_group_form", addGroupDialog);
    var editGroupDialog = $("#js_edit_group_dialog");
    var editGroupError = $(".js_error_group", editGroupDialog);
    var editGroupsForm = $("#js_edit_group_form", editGroupDialog);
    var editGroupField = $("#js_edit_group_filed");
    var removeGroupsDialog = $("#js_remove_group_dialog");

    makeServerGroupsCells(self);
    var groupsCell = self.groupsCell;

    noticeContainer.hide();
    saveChngesBtn.addClass("dynamic_disabled");

    DAL.cells.mode.subscribeValue(function (section) {
      section === "groups" && groupsCell.invalidate();
    });

    Cell.subscribeMultipleValues(function (groups, isEnterprise) {
      if (!isEnterprise) {
        return;
      }

      noticeContainer.hide();
      saveChngesBtn.addClass("dynamic_disabled");
      addGroupBtn.removeClass("dynamic_disabled");

      if (!groups) {
        return renderTemplate("js_server_group", {
          loading: true,
          height: groupsListContainer.height() || 350
        });
      }

      groups.groups.sort(nameComparator);
      _.each(groups.groups, function (group, index) {
        group.nodes.sort(hostNameComparator);
      });

      renderTemplate("js_server_group", {
        allNodes: _.reduce(groups.groups, function (memo, group) { return memo.concat(group.nodes); }, []),
        groups: groups.groups,
        loading: false
      });

      _.each(groups.groups, function (group) {
        var parent = $("#js_group_" + makeSafeForCSS(group.name) + "_wrapper");
        var deleteButton = $(".js_delete_group", parent);
        var editButton = $(".js_edit_group", parent);

        deleteButton.click(function () {
          removeGroups(group.uri);
        });
        editButton.click(function () {
          editGroup(group);
        });
      });

      sortableServerGroups.initialize({
        onChange: function () {
          saveChngesBtn.toggleClass("dynamic_disabled", _.isEqual(groups.groups, sortableServerGroups.groups.groups));
          addGroupBtn.removeClass("dynamic_disabled");
          noticeContainer.hide();
        },
        groups: groups,
        hostNameComparator: hostNameComparator,
        dragSelector: ".js_draggable",
        overSelector: ".js_group_wrapper",
        putIntoSelector: ".js_group_servers",
        overActiveSelector: "dynamic_over",
        emplyListSelector: "dynamic_empty",
        contextSelector: "#js_groups",
        placeholderSelector: "js_drag_placeholder drag_placeholder"
      });
    }, groupsCell, DAL.cells.isEnterpriseCell);

    function errorsHandler(resp, errorHolder) {
      errorHolder.empty();
      var error = JSON.parse(resp.responseText);

      if (_.isObject(error)) {
        var i;
        for (i in error) {
          errorHolder.append(i + " - " + error[i] + " ");
        }
      } else {
        errorHolder.append(error);
      }
    }

    function revisionMismatch(resp) {
      if (resp.status !== 409) {
        return false;
      }

      noticeContainer.show();
      addGroupBtn.addClass("dynamic_disabled");
      saveChngesBtn.addClass("dynamic_disabled");
      var reloadlink = $("<a />").text("Press to sync").click(function () {
        groupsCell.invalidate();
      });
      noticeContainer.empty();
      noticeContainer.append("Error: Revision mismatch. Changes are not applied. ", reloadlink, ".");

      return true;
    }

    addGroupBtn.click(createGroup);
    saveChngesBtn.click(updateGroups);

    addGroupsForm.bind('submit', function (e) {
      e.preventDefault();
      var enteredGroupName = $("#js_new_group_filed").val();
      var overlay = overlayWithSpinner(addGroupDialog);

      $.ajax({
        type: "POST",
        url: sortableServerGroups.groups.uri,
        data: {name: enteredGroupName},
        success: function () {
          addGroupError.empty();
          hideDialog(addGroupDialog);
          groupsCell.invalidate();
        },
        error: function (resp) {
          errorsHandler(resp, addGroupError);
        },
        complete: function () {
          overlay.remove();
        }
      });
    });

    function createGroup(e) {
      if ($(e.currentTarget).hasClass("dynamic_disabled")) {
        return;
      }
      addGroupsForm.get(0).reset();
      addGroupError.empty();
      showDialog(addGroupDialog);
    }

    function editGroup(group) {
      editGroupError.empty();
      showDialog(editGroupDialog);

      editGroupField.val(group.name);

      editGroupsForm.unbind('submit').bind('submit', function (e) {
        e.preventDefault();
        var newName = editGroupField.val();
        var overlay = overlayWithSpinner(editGroupDialog);

        if (group.name === newName) {
          hideDialog(editGroupDialog);
          overlay.remove();
          return;
        }

        $.ajax({
          type: "PUT",
          url: group.uri,
          data: {name: newName},
          success: function () {
            addGroupError.empty();
            hideDialog(editGroupDialog);
            groupsCell.invalidate();
          },
          error: function (resp) {
            errorsHandler(resp, editGroupError);
          },
          complete: function () {
            overlay.remove();
          }
        });
      });
    }

    function updateGroups() {
      if ($(this).hasClass("dynamic_disabled")) {
        return;
      }
      $.ajax({
        type: "PUT",
        url: sortableServerGroups.groups.uri,
        data: JSON.stringify({"groups": sortableServerGroups.groups.groups}),
        success: function () {
          DAL.cells.currentPoolDetailsCell.invalidate();
          DAL.cells.currentPoolDetailsCell.getValue(function () {
            groupsCell.invalidate();
          });
        },
        error: function (resp) {
          if (!revisionMismatch(resp)) {
            errorsHandler(resp, noticeContainer);
          }
        }
      });
    }

    function removeGroups(groupURI) {
      var initialGroups = groupsCell.value.groups;
      var currentGroups = sortableServerGroups.groups.groups;

      if (_.isEqual(initialGroups, currentGroups)) {

        showDialog(removeGroupsDialog, {
          eventBindings: [['.js_delete_button', 'click', function (e) {
            e.preventDefault();
            hideDialog(removeGroupsDialog);

            $.ajax({
              type: "DELETE",
              url: groupURI,
              success: function () {
                groupsCell.invalidate();
              },
              error: function (resp) {
                errorsHandler(resp, noticeContainer);
              }
            });
          }]]
        });
      } else {
        $('html, body').animate({scrollTop: 0}, 250);
        noticeContainer.text("Error: Changes must be saved before deleting the group.");
        noticeContainer.show();
        saveChngesBtn.removeClass("dynamic_disabled");
      }
    }
  }
}
