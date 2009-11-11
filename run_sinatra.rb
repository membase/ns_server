#!/usr/bin/ruby

require 'rubygems'
require 'sinatra'
require 'json'
require 'pp'

set :static, true
set :public, File.expand_path(File.join(File.dirname(__FILE__), 'public'))

module DAO
  module_function
  
end

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
