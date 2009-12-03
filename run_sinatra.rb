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

  def unjson(data)
    response['Content-Type'] = 'application/json'
    JSON.unparse(data)
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
    if id == 12
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
        :stats => {:uri => '/buckets/4/stats?really_for_pool=1'}, # yes we're using bucket stats for now. It's fake anyway
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
        :stats => {:uri => '/buckets/4/stats?really_for_pool=2'}, # yes we're using bucket stats for now. It's fake anyway
        :default_bucket_uri => '/buckets/5'
      }
    end
  end

  def pool_list(options={})
    {
      :implementation_version => "",
      :pools => [{:name => 'Default Pool', :uri => '/pools/12', :defaultBucketURI => '/buckets/4'},
                 {:name => 'Another Pool', :uri => '/pools/13', :defaultBucketURI => '/buckets/5'}]
    }
  end

  def bucket_info(id)
    if id == 4
      {
        :name => 'Excerciser Application',
        :pool_uri => "asdasdasdasd",
        :stats => {:uri => "/buckets/4/stats"},
      }
    else
      {
        :name => 'Excerciser Another',
        :pool_uri => "asdasdasdasd",
        :stats => {:uri => "/buckets/5/stats"},
      }
    end
  end

  # copied from http://en.wikipedia.org/wiki/Low-pass_filter
  # I was thinking about FIR, but this should work too
  def rc_lowpass(data, alpha)
    rv = Array.new(data.size)
    data.each_with_index do |v, i|
      if i == 0
        rv[0] = v
      else
        rv[i] = alpha * v + (1-alpha) * rv[i-1]
      end
    end
    rv
  end

  def generate_samples(seed, size)
    srand(seed)
    values = (0...size).map {|i| rand(100)}
    rc_lowpass(values, 0.5)
  end

  def samples(mode)
    @samples ||= {}
    @samples[mode] ||= begin
                         {"gets" => generate_samples(0xa21 * mode.hash, 20),
                          "misses" => generate_samples(0xa22 * mode.hash, 20),
                          "sets" => generate_samples(0xa23 * mode.hash, 20),
                          "ops" => generate_samples(0xa24 * mode.hash, 20),
                         }
                       end
  end

  def stats(bucket_id, params)
    rv = {
      "op" => {"tstamp" => Time.now.to_i*1000}.merge(self.samples(params['opspersecond_zoom'] || '1hr')),
      "hot_keys" => [{"gets"=>10000,
                       "name"=>"user:image:value",
                       "misses"=>100,
                       "bucket" => "Excerciser application",
                       "type"=>"Persistent"},
                     {"gets"=>10000,
                       "name"=>"user:image:value2",
                       "misses"=>100,
                       "bucket" => "Excerciser application",
                       "type"=>"Cache"},
                     {"gets"=>10000,
                       "name"=>"user:image:value3",
                       "misses"=>100,
                       "bucket" => "Excerciser application",
                       "type"=>"Persistent"},
                     {"gets"=>10000,
                       "name"=>"user:image:value4",
                       "misses"=>100,
                       "bucket" => "Excerciser application",
                       "type"=>"Cache"}]
    }

    samples = rv['op']['ops'].size
    samples_interval = case params['opspersecond_zoom']
                       when 'now'
                         1
                       when '1hr'
                         3600.0/samples
                       when '24hr'
                         86400.0/samples
                       end

    rv['op']['samples_interval'] = samples_interval

    tstamp = rv['op']['tstamp']/1000.0

    cut_number = samples
    if params['opsbysecond_start_tstamp']
      start_tstamp = params['opsbysecond_start_tstamp'].to_i/1000.0

      cut_seconds = tstamp - start_tstamp
      if cut_seconds > 0 && cut_seconds < samples_interval*samples
        cut_number = (cut_seconds/samples_interval).floor
      end
    end

    rotates = tstamp % samples
    %w(gets misses sets ops).each do |name|
      if samples_interval == 1
        rv['op'][name] = (rv['op'][name] * 2)[rotates, samples]
      end
      rv['op'][name] = rv['op'][name][-cut_number..-1]
    end

    rv
  end
end

get "/" do
  redirect "/index.html"
end

user_post "/ping" do
  "pong"
end

user_get "/alerts" do
  $counter = ($counter || 0) + 1
  rv = {
    :email => 'alkondratenko@gmail.com',
    :list => [{
                :number => '1',
                :type => 'warning',
                :tstamp => 1259836260*1000,
                :text => "Above average numbers operations, gets, sets, etc."
              }, {
                :number => '2',
                :type => 'attention',
                :tstamp => 1259836260*1000,
                :text => "Server node down, with issues, etc."
              }, {
                :number => '3',
                :type => 'info',
                :tstamp => 1259836260*1000,
                :text => "Licensing, capacity, NorthScale issues, etc."
              }
             ]}
  $counter.times do |i|
    rv[:list] << {
      :number => i+4,
      :type => 'warning',
      :tstamp => (Time.now.to_f * 1000).floor - ($counter-1-i)*30000,
      :text => 'lorem ipsum'
    }
  end
  if params['lastNumber']
    number = params['lastNumber'].to_i
    newNumber = rv[:list][-1][:number]
    cutNumber = newNumber-number
    rv[:list] = if cutNumber == 0
                  []
                else
                  rv[:list][-cutNumber..-1]
                end
  end
  unjson(rv)
end

user_get "/pools" do
  unjson(DAO.current.pool_list())
end

user_get "/pools/:id" do
  unjson(DAO.current.pool_info(params[:id].to_i))
end

user_get "/buckets/:id" do
  unjson(DAO.current.bucket_info(params[:id].to_i))
end

user_get "/buckets/:id/stats" do
  unjson(DAO.current.stats(params[:id].to_i, params))
end
