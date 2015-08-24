angular.module('mnContenteditable', [
]).directive('mnContenteditable', function ($sce) {

  return {
    restrict: 'A', // only activate on element attribute
    priority: 0,
    require: '?ngModel',
    link: function(scope, element, attrs, ngModel) {
      if (!ngModel) {
        return;
      } // do nothing if no ng-model

      var isFocused = false;
      // Specify how UI should be updated
      ngModel.$render = function () {
        if (isFocused) {
          return;
        }
        element.html($sce.getTrustedHtml(ngModel.$viewValue || ''));
        read();
      };

      element.on('keydown', function (event) {
        //IE inserts tabulation in contenteditable tag instead of make focus on next element,
        //absolutely unfriendly when you have no mouse
        //but after text have selected and tabulation pressed it behaves like other browser
        //unfortunately works only when input has text
        if (event.keyCode == 9) {
          document.execCommand('selectAll', true, null);
        }
      });

      element.on('blur', function () {
        isFocused = false;
      });
      element.on('focus', function () {
        isFocused = true;
      });
      element.on('paste', function (e) {
        var clipboardData = (e.originalEvent || e).clipboardData || $window.clipboardData;
        try {
          var text = clipboardData.getData('text/plain');
          $window.document.execCommand('insertText', false, text);
        } catch (_e) {
          var text = clipboardData.getData('Text');
          try {
            document.selection.createRange().pasteHTML(text);
          } catch (_e) {
            try {
              document.execCommand('InsertHTML', false, text);
            } catch (_e) {
              // if the getting text from clipboard fails we short-circuit return to allow
              // the browser handle the paste natively (i.e. we don't call preventDefault().)
              return;
            }
          }
        }
        e.preventDefault();
      });

      // Listen for change events to enable binding
      element.on('blur keyup change', read);

      // Write data to the model
      function read() {
        ngModel.$setViewValue(element.text());
      }
    }
  };
});