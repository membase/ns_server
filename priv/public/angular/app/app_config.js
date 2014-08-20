angular.module('app').config(function ($httpProvider) {
  $httpProvider.defaults.headers.common['invalid-auth-response'] = 'on';
  $httpProvider.defaults.headers.common['Cache-Control'] = 'no-cache';
  $httpProvider.defaults.headers.common['Pragma'] = 'no-cache';
  $httpProvider.defaults.headers.common['ns_server-ui'] = 'yes';
});