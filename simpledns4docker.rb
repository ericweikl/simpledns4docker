#!/usr/bin/env ruby

require 'rubydns'

INTERFACES = [
  [:udp, "0.0.0.0", 5300],
  [:tcp, "0.0.0.0", 5300]
]

Name = Resolv::DNS::Name
IN = Resolv::DNS::Resource::IN

class DnsServer < RubyDNS::Server
  
  def initialize
    super({})
    @lookup = {}
    @upstream = RubyDNS::Resolver.new([[:udp, "8.8.8.8", 53], [:tcp, "8.8.8.8", 53]])
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
        @server.add get_ip(cid), get_host(cid)
      when 'die'
        @server.remove get_host(cid)
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
    server = DnsServer.new
    @handler = DockerEventHandler.new server
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
