(function () {
  "use strict";

  angular
    .module("mnUserRolesService", ['mnHelper'])
    .factory("mnUserRolesService", mnUserRolesFactory);

  function mnUserRolesFactory($q, $http, mnHelper) {
    var mnUserRolesService = {
      getState: getState,
      addUser: addUser,
      getRoles: getRoles,
      deleteUser: deleteUser,
      getRolesByRole: getRolesByRole,
      getRolesTree: getRolesTree,
      prepareUserRoles: prepareUserRoles
    };

    return mnUserRolesService;

    function getRoles() {
      return $http({
        method: "GET",
        url: "/settings/rbac/roles"
      }).then(function (resp) {
        return resp.data;
      });
    }

    function sort(array) {
      if (angular.isArray(array) && angular.isArray(array[0])) {
        array.forEach(sort);
        array.sort(function(a, b) {
          var aHasTitle = angular.isArray(a[1]) || !!a[0].bucket_name;
          var bHasTitle = angular.isArray(b[1]) || !!b[0].bucket_name;
          if (!aHasTitle && bHasTitle) {
            return -1;
          }
          if (aHasTitle && !bHasTitle) {
            return 1;
          }
          return 0;
        });
      }
    }

    function getRolesTree(roles) {
      roles = _.sortBy(roles, "name");
      var roles1 = _.groupBy(roles, 'role');
      var roles2 = _.groupBy(roles1, function (array, role) {
        return role.split("_")[0];
      });
      var roles3 = _.values(roles2);
      sort(roles3);
      return roles3;
    }

    function getUser(user) {
      return $http({
        method: "GET",
        url: getUserUrl(user)
      });
    }

    function getUsers(params) {
      var config = {
        method: "GET",
        url: "/settings/rbac/users"
      };
      if (params) {
        config.params = {
          pageSize: params.pageSize,
          startFromDomain: params.startFromDomain,
          startFrom: params.startFrom
        };
      }
      return $http(config);
    }

    function deleteUser(user) {
      return $http({
        method: "DELETE",
        url: getUserUrl(user)
      });
    }

    function getUserUrl(user) {
      return "/settings/rbac/users/" + encodeURIComponent(user.domain) + "/"  + encodeURIComponent(user.id);
    }

    function prepareUserRoles(userRoles) {
      return $q.all([getRolesByRole(userRoles), getRolesByRole()])
        .then(function (rv) {
          var userRolesByRole = rv[0];
          var rolesByRole = rv[1];
          var i;
          for (i in userRolesByRole) {
            if (!rolesByRole[i]) {
              delete userRolesByRole[i];
            } else {
              userRolesByRole[i] = true;
            }
          }

          return userRolesByRole;
        });
    }

    function getRolesByRole(userRoles) {
      return (userRoles ? $q.when(userRoles) : getRoles()).then(function (roles) {
        var rolesByRole = {};
        angular.forEach(roles, function (role) {
          rolesByRole[role.role + (role.bucket_name ? '[' + role.bucket_name + ']' : '')] = role;
        });
        return rolesByRole;
      });
    }

    function doAddUser(user, roles) {
      var data = {
        roles: roles.join(','),
        name: user.name
      };
      if (user.domain === "local") {
        data.password = user.password;
      }

      return $http({
        method: "PUT",
        data: data,
        url: getUserUrl(user)
      });
    }

    function prepareRolesForSaving(roles) {
      if (_.isArray(roles)) {
        return _.map(roles, function (role) {
          return role.role + (role.bucket_name ? '[' + role.bucket_name + ']' : '');
        });
      }
      if (roles.admin) {
        return ["admin"];
      }
      if (roles.cluster_admin) {
        return ["cluster_admin"];
      }
      var i;
      for (i in roles) {
        var name = i.split("[");
        if (name[1] !== "*]" && roles[name[0] + "[*]"]) {
          delete roles[i];
        }
      }
      return mnHelper.checkboxesToList(roles);

    }

    function addUser(user, roles, isEditingMode) {
      if (!user || !user.id) {
        return $q.reject({username: "username is required"});
      }
      roles = prepareRolesForSaving(roles);
      if (!roles || !roles.length) {
        return $q.reject({roles: "at least one role should be added"});
      }
      if (isEditingMode) {
        return doAddUser(user, roles);
      } else {
        return getUser(user).then(function (users) {
          return $q.reject({username: "username already exists"});
        }, function () {
          return doAddUser(user, roles);
        });
      }

    }

    function getState(params) {
      return getUsers(params).then(function (resp) {
        var i;
        for (i in resp.data.links) {
          resp.data.links[i] = resp.data.links[i].split("?")[1]
            .split("&")
            .reduce(function(prev, curr, i, arr) {
              var p = curr.split("=");
              prev[decodeURIComponent(p[0])] = decodeURIComponent(p[1]);
              return prev;
            }, {});
        }
        return resp.data;
      });
    }
  }
})();
