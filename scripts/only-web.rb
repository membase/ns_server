#!/usr/bin/env ruby

require 'rubygems'
gem 'sinatra', '>= 1.3.2' # for :public_folder
require 'sinatra/base'
require 'active_support/core_ext'
require 'pp'
require 'optparse'

$PRIVROOT = File.expand_path(File.join(File.dirname(__FILE__), '../priv'))
$DOCROOT = $PRIVROOT + "/public"

def build_all_images_js!
  all_images_names = Dir.chdir($DOCROOT) do
    Dir.glob("images/**/*").reject {|n| File.directory? n}
  end
  File.open($DOCROOT + "/js/all-images.js", "wt") do |file|
    file << "var AllImages = " << all_images_names.to_json << ";\n"
  end
end

build_all_images_js!

class Middleware
  def initialize(app)
    @app = app
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

class NSServer < Sinatra::Base
  use Middleware

  set :public_folder, $DOCROOT

  get "/" do
    redirect "/index.html"
  end
end


OptionParser.new do |opts|
  script_name = File.basename($0)
  opts.banner = "Usage: #{script_name} [options]"

  NSServer.set :port, 8080

  opts.on('-x', 'Turn on the mutex lock (default is off)') do
    NSServer.set :lock, true
  end
  opts.on('-e env', 'Set the environment (default is development)') do |opt|
    NSServer.set :environment, opt.to_sym
  end
  opts.on('-s server', 'Specify rack server/handler (default is thin)') do |opt|
    NSServer.set :server, opt
  end
  opts.on('-p port', 'Set the port (default is 8080)') do |opt|
    NSServer.set :port, opt.to_i
  end
  opts.on('-o addr', 'Set the host (default is localhost)') do |opt|
    NSServer.set :bind, opt
  end
  opts.on('-t', '--tests', 'Run ns_server UI tests') do |opt|
    $run_tests = true
  end
  opts.on_tail('-h', '--help', 'Show this message') do
    puts opts.help
    exit
  end

end.parse!

Dir.chdir(File.dirname(__FILE__))

NSServer.run! do
  if $run_tests
    Thread.new do
      cmd = "phantomjs #{$PRIVROOT}/ui_tests/deps/casperjs/bootstrap.js --casper-path=#{$PRIVROOT}/ui_tests/deps/casperjs --cli #{$PRIVROOT}/ui_tests/casperjs-testrunner.coffee #{$PRIVROOT}/ui_tests/suite/ " +
            "--base-url=http://#{NSServer.settings.bind || "127.0.0.1"}:#{NSServer.settings.port.to_s}/index.html"
      puts "cmd: #{cmd}"
      ok = system(cmd)
      unless ok
        puts("phantomjs command failed")
      end
      Process.exit!(ok ? 0 : 1)
    end
  end
end
