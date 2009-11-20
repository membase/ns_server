#!/usr/bin/ruby

require 'rubygems'
require 'sinatra'
require 'json'
require 'pp'

set :static, true
set :public, File.expand_path(File.join(File.dirname(__FILE__), 'public'))

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
#    sleep 1
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
    if id == '12'
      {
        :name => 'Default Pool',
        :bucket => [
                     {:name => 'Excerciser Application',
                       :uri => '/buckets/4'}
                    ],
        :node => [
                  {
                    :name => "first_node",
                    :uri => "https://first_node.in.pool.com:80/pool/Default Pool/node/first_node/",
                    :fqdn => "first_node.in.pool.com",
                    :ip_address => "10.0.1.20",
                    :running => true,
                    :ports => [ 11211 ]
                  },
                  {
                    :name => "second_node",
                    :uri => "https://second_node.in.pool.com:80/pool/Default Pool/node/second_node/",
                    :fqdn => "second_node.in.pool.com",
                    :ip_address => "10.0.1.21",
                    :running => true,
                    :ports => [ 11211 ]
                  }
                 ],
        :default_bucket_uri => '/buckets/4'
      }
    else
      {
        :name => 'Another Pool',
        :bucket => [
                     {
                       :name => 'Excerciser Another',
                       :uri => '/buckets/5'
                     }
                    ],
        :node => [
                  {
                    :name => "first_node",
                    :uri => "https://first_node.in.pool.com:80/pool/Another Pool/node/first_node/",
                    :fqdn => "first_node.in.pool.com",
                    :ip_address => "10.0.1.22",
                    :running => true,
                    :uptime => 123443,
                    :ports => [ 11211 ]
                  },
                  {
                    :name => "second_node",
                    :uri => "https://second_node.in.pool.com:80/pool/Another Pool/node/second_node/",
                    :fqdn => "second_node.in.pool.com",
                    :ip_address => "10.0.1.22",
                    :running => true,
                    :uptime => 123123,
                    :ports => [ 11211 ]
                  }
                 ],
        :default_bucket_uri => '/buckets/5'
      }
    end
  end

  def pool_list(options={})
    [{:name => 'Default Pool', :uri => '/pools/12', :defaultBucketURI => '/buckets/4'},
     {:name => 'Another Pool', :uri => '/pools/13', :defaultBucketURI => '/buckets/5'}]
  end

  def bucket_info(id)
    {
      :name => 'Excerciser Application',
      :pool_uri => "asdasdasdasd",
      :op_stats_uri => "/buckets/4/op_stats",
      :key_stats_uri => "/buckets/4/key_stats"
    }
  end

  def op_stats(bucket_id)
    {"gets"=>[25, 10, 5, 46, 100, 74],
      "misses"=>[100, 74, 25, 10, 5, 46],
      "sets"=>[74, 25, 10, 5, 46, 100],
      "ops"=>[10, 5, 46, 100, 74, 25]}    
  end

  def key_stats(bucket_id)
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
       "type"=>"Cache"}]
  end
end

get "/" do
  redirect "/index.html"
end

user_post "/ping" do
  "pong"
end

user_get "/pools" do
  list = DAO.current.pool_list()
  JSON.unparse(list)
end

user_get "/pools/:id" do
  JSON.unparse(DAO.current.pool_info(params[:id].to_i))
end

user_get "/buckets/:id" do
  JSON.unparse(DAO.current.bucket_info(params[:id].to_i))
end

user_get "/buckets/:id/op_stats" do
  response['Content-Type'] = 'application/json'
  JSON.unparse(DAO.current.op_stats(params[:id].to_i))
end

user_get "/buckets/:id/key_stats" do
  response['Content-Type'] = 'application/json'
  JSON.unparse(DAO.current.key_stats(params[:id].to_i))
end
