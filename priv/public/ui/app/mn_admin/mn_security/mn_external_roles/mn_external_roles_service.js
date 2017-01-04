(function () {
  "use strict";

  angular
    .module("mnExternalRolesService", [])
    .factory("mnExternalRolesService", mnExternalRolesFactory);

  function mnExternalRolesFactory($q, $http) {
    var mnExternalRolesService = {
      getState: getState,
      addUser: addUser,
      getRoles: getRoles,
      deleteUser: deleteUser,
      getRolesByRole: getRolesByRole,
      getRoleFromRoles: getRoleFromRoles
    };

    return mnExternalRolesService;

    function getRoles() {
      return $http({
        method: "GET",
        url: "/settings/rbac/roles"
      }).then(function (resp) {
        return resp.data;
      });
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

    function getRoleFromRoles(rolesByRole, role) {
      if (!rolesByRole) {
        return;
      }
      return rolesByRole[role.role] && (role.bucket_name ? rolesByRole[role.role][role.bucket_name] : rolesByRole[role.role]);
    }

    function getUserUrl(user) {
      return "/settings/rbac/users/" + encodeURIComponent(user.type) + "/"  + encodeURIComponent(user.id);
    }

    function getRolesByRole(roles) {
      return (roles ? $q.when(roles) : getRoles()).then(function (roles) {
        var rolesByRole = {};
        angular.forEach(roles, function (role) {
          rolesByRole[role.role] = rolesByRole[role.role] || {};
          if (role.bucket_name) {
            rolesByRole[role.role][role.bucket_name] = role;
          } else {
            rolesByRole[role.role] = _.extend(rolesByRole[role.role], role);
          }
        });
        return rolesByRole;
      });
    }

    function doAddUser(user, roles) {
      var rolesWithBucketName = _.map(roles, function (role) {
        if (role.bucket_name) {
          return role.role + "[" + role.bucket_name + "]";
        } else {
          return role.role;
        }
      });
      var data = {
        roles: rolesWithBucketName.join(','),
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

    function addUser(user, roles, originalUser) {
      if (!user || !user.id) {
        return $q.reject({username: "username is required"});
      }
      if (!roles || !roles.length) {
        return $q.reject({roles: "at least one role should be added"});
      }
      if (originalUser && originalUser.id === user.id) {
        if (originalUser.type === user.type) {
          return doAddUser(user, roles);
        } else {
          return doAddUser(user, roles).then(function () {
            return deleteUser(originalUser);
          });
        }
      } else {
        return getUsers().then(function (users) {
          if (_.find(users, {id: user.id})) {
            return $q.reject({username: "username already exists"});
          } else {
            if (originalUser && originalUser.id !== user.id) {
              return doAddUser(user, roles).then(function () {
                return deleteUser(originalUser);
              });
            } else {
              return doAddUser(user, roles);
            }
          }
        });
      }
    }

    function getState() {
      return getUsers().then(function (users) {
        return {users: users};
      })
    }
  }
})();
