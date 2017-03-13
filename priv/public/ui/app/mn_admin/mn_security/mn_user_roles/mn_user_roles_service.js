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

    function getRolesTree(roles) {
      var roles1 = _.groupBy(roles, 'role');
      var roles2 = _.groupBy(roles1, function (array, role) {
        return role.split("_")[0];
      });

      return roles2;
    }

    function getUsers() {
      return $http({
        method: "GET",
        url: "/settings/rbac/users"
      }).then(function (resp) {
        return resp.data;
      });
    }

    function deleteUser(user) {
      return $http({
        method: "DELETE",
        url: getUserUrl(user)
      });
    }

    function getUserUrl(user) {
      return "/settings/rbac/users/" + encodeURIComponent(user.type) + "/"  + encodeURIComponent(user.id);
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
      if (user.type === "builtin") {
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

    function addUser(user, roles) {
      if (!user || !user.id) {
        return $q.reject({username: "username is required"});
      }
      roles = prepareRolesForSaving(roles);
      if (!roles || !roles.length) {
        return $q.reject({roles: "at least one role should be added"});
      }
      return doAddUser(user, roles);
    }

    function getState() {
      return getUsers().then(function (users) {
        return {users: users};
      })
    }
  }
})();
