#!/usr/bin/ruby

require 'rubygems'
require 'sinatra'

set :static, true
set :public, File.expand_path(File.join(File.dirname(__FILE__), 'public'))

get "/" do
  redirect "/index.html"
end
