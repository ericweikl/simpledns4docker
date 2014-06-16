#!/usr/bin/env ruby

# simpledns4docker
# https://github.com/ericweikl/simpledns4docker
# MIT licensed
#
# Copyright (C) 2014 Eric Weikl


require 'rubydns'
require 'optparse'

options = {
  :port => 53,
  :upstream => "8.8.8.8",
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: simpledns4docker.rb [options]'

  opts.on("-p", "--port [PORT]", "listen on port PORT (default: 53)") do |port|
    options[:port] = port
  end
  opts.on("-u", "--upstream [IP]", "use IP as an upstream server (default: 8.8.8.8") do |ip|
    options[:upstream] = ip
  end
  opts.on_tail("-h", "--help", "show this message") do
    puts opts
    exit
  end
end

parser.parse(ARGV)

UPSTREAM = options[:upstream]
INTERFACES = [
  [:udp, "0.0.0.0", options[:port]],
  [:tcp, "0.0.0.0", options[:port]]
]

Name = Resolv::DNS::Name
IN = Resolv::DNS::Resource::IN

class DnsServer < RubyDNS::Server
  
  def initialize upstream
    super({})
    @lookup = {}
    @upstream = RubyDNS::Resolver.new([[:udp, upstream, 53], [:tcp, upstream, 53]])
  end

  def add ip, host
    logger.debug "registering #{host} => #{ip}"
    @lookup[host] = ip 
  end

  def remove host
    logger.debug "removing #{host}"
    @lookup.delete(host)
  end

  def process(name, resource_class, transaction)
    if resource_class == IN::A
      ip = @lookup[name]
      if ip
        logger.debug "internal lookup for #{name} => #{ip}"
        return transaction.respond!(ip)
      end
    end
    transaction.passthrough!(@upstream)
  end
end

class DockerEventHandler

  def initialize server
    @server = server
  end

  def on_data data
    match = data.match(/.*\]\s*([^:]+).*\)\s*(\w+).*\s*/)
    cid = match[1]
    event = match[2]
    case event
      when 'start'
        add cid
      when 'die'
        remove cid
    end
  end

  def add cid
    @server.add get_ip(cid), get_host(cid)
  end

  def remove cid
    @server.remove get_host(cid)
  end

  def add_existing_containers
    `docker ps -q`.each_line do |cid|
      add cid
    end
  end

  def get_host cid
    `docker inspect --format '{{ .Config.Hostname }}' #{cid}`.strip!
  end

  def get_ip cid
    `docker inspect --format '{{ .NetworkSettings.IPAddress }}' #{cid}`.strip!
  end

end

module Application
  def post_init
    server = DnsServer.new UPSTREAM
    @handler = DockerEventHandler.new server
    @handler.add_existing_containers()
    server.run(:listen => INTERFACES)
  end

  def receive_data(data)
    @handler.on_data data
  end

  def unbind
    exit 1
  end
end

EventMachine.run do
  EM.popen("docker events", Application)
end
