#!/usr/bin/ruby

require 'rubygems'
require 'sinatra'
require 'json'
require 'pp'

set :static, true
set :public, File.expand_path(File.join(File.dirname(__FILE__), 'public'))

class DAO
  class BadUser < Exception; end
  def self.for_user(username, password)
    unless username == 'admin' && password == 'admin'
      raise BadUser
    end

    self.new
  end

  def self.current
    Thread.current['DAO']
  end
  def self.current=(v)
    Thread.current['DAO'] = v
  end

  def pool_info(id)
    {
      :servers => [{
                     :id => 112,
                     :ip => '12.12.12.12',
                     :status => 'up',
                     :uptime => 1231233},
                   {
                     :id => 113,
                     :ip => '12.12.12.13',
                     :status => 'down',
                     :uptime => 1231232}],
      :buckets => [{
                     :name => 'excerciser',
                     :id => 123}]
    }
  end

  def pool_list(options={})
    rv = [{:name => 'Default Pool', :id => 12}]
    if options[:with_buckets]
      rv[0][:buckets] = [{:name => 'Excerciser Application', :id => 23}]
    end
    rv
  end
end

helpers do
  def auth_credentials
    @auth ||=  Rack::Auth::Basic::Request.new(request.env)
    if @auth.provided?
      @auth.credentials
    end
  end

  def with_valid_user
    login, password = *auth_credentials
    dao = begin
            DAO.for_user(login, password)
          rescue DAO::BadUser
            response['WWW-Authenticate'] = 'Basic realm="api"'
            throw(:halt, 401)
          end
    old, DAO.current = DAO.current, dao
    begin
      yield
    ensure
      DAO.current = old
    end
  end
end

def user_method(method, *args, &block)
  raise "need block" unless block_given?
  self.send(method, *args) do |*unsupported_inner_args|
    with_valid_user do
      instance_eval(&block)
    end
  end
end

# same as <tt>get</tt> but requiring valid user
def user_get(*args, &block)
  user_method(:get, *args, &block)
end

# same as <tt>post</tt> but requiring valid user
def user_post(*args, &block)
  user_method(:post, *args, &block)
end

# same as <tt>put</tt> but requiring valid user
def user_put(*args, &block)
  user_method(:put, *args, &block)
end

# same as <tt>delete</tt> but requiring valid user
def user_delete(*args, &block)
  user_method(:delete, *args, &block)
end

get "/" do
  redirect "/index.html"
end

user_post "/ping" do
  "pong"
end

user_get "/pools" do
  JSON.unparse(DAO.current.pool_list({:with_buckets => params[:buckets]}))
end

user_get "/buckets/:id/stats" do
  response['Content-Type'] = 'application/json'
  JSON.unparse("stats"=>
               {"gets"=>[25, 10, 5, 46, 100, 74],
                 "misses"=>[100, 74, 25, 10, 5, 46],
                 "hot_keys"=>
                 [{"gets"=>10000,
                    "name"=>"user:image:value",
                    "misses"=>100,
                    "type"=>"Persistent"},
                  {"gets"=>10000,
                    "name"=>"user:image:value2",
                    "misses"=>100,
                    "type"=>"Cache"},
                  {"gets"=>10000,
                    "name"=>"user:image:value3",
                    "misses"=>100,
                    "type"=>"Persistent"},
                  {"gets"=>10000,
                    "name"=>"user:image:value4",
                    "misses"=>100,
                    "type"=>"Cache"}],
                 "sets"=>[74, 25, 10, 5, 46, 100],
                 "ops"=>[10, 5, 46, 100, 74, 25]},
               "servers"=>
               [{"name"=>"asd",
                  "threads"=>8,
                  "cache"=>"3gb",
                  "running"=>true,
                  "port"=>12312,
                  "os"=>"none",
                  "version"=>"123",
                  "uptime"=>1231293},
                {"name"=>"serv2",
                  "threads"=>0,
                  "cache"=>"",
                  "running"=>false,
                  "port"=>12323,
                  "os"=>"win",
                  "version"=>"123",
                  "uptime"=>123123},
                {"name"=>"serv3",
                  "threads"=>5,
                  "cache"=>"13gb",
                  "running"=>true,
                  "port"=>12323,
                  "os"=>"bare metal",
                  "version"=>"123",
                  "uptime"=>12312}])
end
