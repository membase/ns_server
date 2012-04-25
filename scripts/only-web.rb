#!/usr/bin/ruby

require 'rubygems'
gem 'sinatra', '>= 1.3.2' # for :public_folder
require 'sinatra'
require 'active_support/core_ext'
require 'pp'

$DOCROOT = File.expand_path(File.join(File.dirname(__FILE__), '../priv/public'))

def sh(cmd)
  puts "# #{cmd}"
  ok = system cmd
  unless ok
    str = "FAILED! #{$?.inspect}"
    puts str
    raise str
  end
end

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
    if req.path_info == "/index.html"
      text = IO.read($DOCROOT + "/index.html").gsub("</body>", "<script src='/js/hooks.js'></script></body>")
      return [200, {'Content-Type' => 'text/html; charset=utf-8'}, [text]]
    elsif req.path_info.starts_with?('/js/')
      path = req.path_info
      if File.file?(path)
        return [200, {'Content-Type' => 'application/javascript'}, IO.readlines(path, 'r')]
      end
    end

    @app.call(env)
  end
end

helpers do
  def auth_credentials
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    if @auth.provided?
      @auth.credentials
    end
  end
end

use Middleware

set :public_folder, $DOCROOT

get "/" do
  redirect "/index.html"
end

get "/test_auth" do
  user, pwd = *auth_credentials
  if user != 'admin' || pwd != 'admin'
#    response['WWW-Authenticate'] = 'Basic realm="api"'
    response['Cache-Control'] = 'no-cache must-revalidate'
    throw(:halt, 401)
  end
  "OK"
end

if ARGV.size == 0
  name = "ruby #{$0} -p 8080"
  puts name
  system name
  exit 0
end
