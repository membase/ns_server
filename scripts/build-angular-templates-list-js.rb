#!/usr/bin/env ruby

$PRIVROOT = File.expand_path(File.join(File.dirname(__FILE__), '../priv'))
$DOCROOT = $PRIVROOT + "/public/ui/"

angular_templates_list = Dir.chdir($DOCROOT) do
  Dir.glob(File.join("**", "*.html"))
end
File.open($DOCROOT + "templates-list.js", "wt") do |file|
  file << "var angularTemplatesList = " << angular_templates_list << ";\n"
end