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
    user, password = *auth_credentials
    # fake auth here
    if user == 'admin' && password == 'admin'
      yield user
    else
      throw(:halt, [401, "Not authorized\n"])
    end
  end
end

get "/" do
  redirect "/index.html"
end

post "/ping" do
  with_valid_user do |user|
    "pong"
  end
end

get "/buckets/:id/stats" do
  response['Content-Type'] = 'application/json'
  <<HERE
{
  stats: {
    ops: [10, 5, 46, 100, 74, 25],
    gets: [25, 10, 5, 46, 100, 74],
    sets: [74, 25, 10, 5, 46, 100],
    misses: [100, 74, 25, 10, 5, 46],
    hot_keys: [{name:'user:image:value', type:'Persistent', gets: 10000, misses:100},
               {name:'user:image:value2', type:'Cache', gets: 10000, misses:100},
               {name:'user:image:value3', type:'Persistent', gets: 10000, misses:100},
               {name:'user:image:value4', type:'Cache', gets: 10000, misses:100}]},
  servers: [{name: 'asd', port: 12312, running: true, uptime: 1231233+60, cache: '3gb', threads: 8, version: '123', os: 'none'},
               {name: 'serv2', port: 12323, running: false, uptime: 123123, cache: '', threads: 0, version: '123', os: 'win'},
               {name: 'serv3', port: 12323, running: true, uptime: 12312, cache: '13gb', threads: 5, version: '123', os: 'bare metal'}]}
HERE
end
