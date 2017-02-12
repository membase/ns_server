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
      getRolesTree: getRolesTree
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

    function getRolesTree() {
      return getRoles().then(function (roles) {
        var roles1 = _.groupBy(roles, 'role');
        var roles2 = _.groupBy(roles1, function (array, role) {
          return role.split("_")[0];
        });

        return roles2;
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

    function getUserUrl(user) {
      return "/settings/rbac/users/" + encodeURIComponent(user.type) + "/"  + encodeURIComponent(user.id);
    }

    function getRolesByRole(userRoles, forAddDialog) {
      return (userRoles ? $q.when(userRoles) : getRoles()).then(function (roles) {
        var rolesByRole = {};
        angular.forEach(roles, function (role) {
          rolesByRole[role.role + (role.bucket_name ? '[' + role.bucket_name + ']' : '')] = forAddDialog ? true : role;
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

    function addUser(user, roles, originalUser) {
      if (!user || !user.id) {
        return $q.reject({username: "username is required"});
      }
      roles = mnHelper.checkboxesToList(roles);
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
