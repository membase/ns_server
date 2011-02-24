#!/usr/bin/ruby
Dir.chdir(File.dirname($0))

$DOCROOT = 'priv/public'
$INDIVIDUAL_JS = true
$HOOKS = false

# TODO: add test JS back as possible output option
# replacement = "/js/t-all.js\""

if $INDIVIDUAL_JS
  files = IO.readlines('priv/public/js/dev/app.js').grep(%r|//= require <(.*)>$|) {|_d| $1}
  files.delete("all-images.js")
  files << "app.js"
  if $HOOKS
    files << "hooks.js"
  end
  files = files.map {|f| "/js/dev/#{f}"}
  replacement = "<script src=\"" << files.join("\"></script><script src=\"") << "\"></script>"
else
  replacement = "<script src=\"/js/all.js\"></script>"
end
replacement = "<!--@scripts-->" << replacement
text = IO.read($DOCROOT + "/index.html").gsub(Regexp.compile(/\<\!--\@scripts--\>(.*)/), replacement)
File.open($DOCROOT + '/index.html', 'w') do |f2|  
  # use "\n" for two lines of text  
  f2.puts text
  print "priv/public/index.html has been updated\n"
end
