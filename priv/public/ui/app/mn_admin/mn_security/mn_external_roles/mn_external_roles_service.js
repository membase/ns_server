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
      getRolseByRole: getRolseByRole
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

    function deleteUser(name) {
      return $http({
        method: "DELETE",
        url: "/settings/rbac/users/" + encodeURIComponent(name)
      });
    }

    function getRolseByRole(roles) {
      return (roles ? $q.when(roles) : getRoles()).then(function (roles) {
        var rolesByRole = {};
        angular.forEach(roles, function (role) {
          rolesByRole[role.role] = role;
        });
        return rolesByRole;
      });
    }

    function addUser(user, roles) {
      if (!user || !user.id) {
        return $q.reject("username is required");
      }
      if (!roles || !roles.length) {
        return $q.reject("at least one role should be added");
      }
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
        url: "/settings/rbac/users/" + encodeURIComponent(user.id)
      });
    }

    function getState() {
      return getUsers().then(function (users) {
        return {users: users};
      })
    }
  }
})();
