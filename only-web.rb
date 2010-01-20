#!/usr/bin/ruby

require 'rubygems'
require 'sinatra'
require 'active_support'
require 'pp'

Dir.chdir(File.dirname($0))

$DOCROOT = 'priv/public'

def sh(cmd)
  puts "# #{cmd}"
  ok = system cmd
  unless ok
    str = "FAILED! #{$?.inspect}"
    puts str
    raise str
  end
end

$DEVMODE = true

class Middleware
  def initialize(app)
    @app = app
  end

  $JS_ESCAPE_MAP = { '\\' => '\\\\', '</' => '<\/', "\r\n" => '\n', "\n" => '\n', "\r" => '\n', '"' => '\\"', "'" => "\\'" }
  def escape_javascript(javascript)
    if javascript
      javascript.gsub(/(\\|<\/|\r\n|[\n\r"'])/) { $JS_ESCAPE_MAP[$1] }
    else
      ''
    end
  end

  def call(env)
    req = Rack::Request.new(env)
    if req.path_info == '/js/t-all.js'
      begin
        sh "sprocketize -I priv/js priv/js/app.js priv/js/hooks.js >priv/public/js/t-all.js"
      rescue
        status, headers, body = @app.call(env)
        body = ["alert('#{escape_javascript($!.inspect)}')"]
        return [200, {'Content-Type' => 'application/javascript'}, body]
      end
    elsif req.path_info == "/index.html"
      replacement = "/js/t-all.js\""
      if $DEVMODE
        files = IO.readlines('priv/js/app.js').grep(%r|//= require <(.*)>$|) {|_d| $1}
        files << "app.js" << "hooks.js"
        files = files.map {|f| "/js/#{f}"}
        replacement = files.join("\"></script><script src=\"") << "\""
      end
      text = IO.read($DOCROOT + "/index.html").gsub(Regexp.compile(Regexp.escape("/js/all.js\"")), replacement)
      return [200, {'Content-Type' => 'text/html; charset=utf-8'}, [text]]
    elsif req.path_info.starts_with?('/js/')
      path = req.path_info
      apath = "priv/" + path
      if File.file?(apath)
        return [200, {'Content-Type' => 'application/javascript'}, IO.readlines(apath, 'r')]
      end
    end

    @app.call(env)
  end
end


use Middleware

set :public, $DOCROOT

if ARGV.size == 0
  exec $0, "-p", "8080" #, "-s", "webrick"
end
