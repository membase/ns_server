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

    function deleteUser(id) {
      return $http({
        method: "DELETE",
        url: "/settings/rbac/users/" + encodeURIComponent(id)
      });
    }

    function getRoleFromRoles(rolesByRole, role) {
      return rolesByRole[role.role] && (role.bucket_name ? rolesByRole[role.role][role.bucket_name] : rolesByRole[role.role]);
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

    function doAddUser(user, roles, id) {
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
      return $http({
        method: "PUT",
        data: data,
        url: "/settings/rbac/users/" + encodeURIComponent(id)
      });
    }

    function addUser(user, roles, originalUser) {
      if (!user || !user.id) {
        return $q.reject("username is required");
      }
      if (!roles || !roles.length) {
        return $q.reject("at least one role should be added");
      }
      if (originalUser) {
        if (originalUser.id !== user.id) {
          return deleteUser(originalUser.id).then(function () {
            return doAddUser(user, roles, user.id);
          });
        } else {
          return doAddUser(user, roles, originalUser.id);
        }
      } else {
        return getUsers().then(function (users) {
          if (_.find(users, {id: user.id})) {
            return $q.reject("username already exist");
          } else {
            return doAddUser(user, roles, user.id);
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
