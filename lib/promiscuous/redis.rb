require 'redis'

module Promiscuous::Redis
  mattr_accessor :master

  def self.connect
    disconnect
    self.master = new_connection
  end

  def self.disconnect
    self.master.client.disconnect if self.master
    self.master = nil
  end

  def self.new_connection(url=nil)
    url ||= Promiscuous::Config.redis_url
    redis = ::Redis.new(:url => url, :tcp_keepalive => 60)
    redis.client.connect

    version = redis.info['redis_version']
    unless Gem::Version.new(version) >= Gem::Version.new('2.6.0')
      raise "You are using Redis #{version}. Please use Redis 2.6.0 or later."
    end

    redis
  end

  def self.new_celluloid_connection
    new_connection.tap do |redis|
      redis.client.connection.instance_eval do
        @sock = Celluloid::IO::TCPSocket.from_ruby_socket(@sock)
        @sock.instance_eval do
          extend ::Redis::Connection::SocketMixin
          @timeout = nil
          @buffer = ""

          def _read_from_socket(nbytes)
            readpartial(nbytes)
          end
        end
      end
    end
  end

  def self.lost_connection_exception
    Promiscuous::Error::Connection.new(:service => :redis)
  end

  def self.ensure_connected
    Promiscuous::Redis.master.ping
  rescue
    raise lost_connection_exception
  end

  def self.method_missing(name, *args, &block)
    self.master.__send__(name, *args, &block)
  end

  class Mutex
    def initialize(key, options={})
      # TODO remove old code with orig_key
      @orig_key = key.to_s
      @key = "#{key}:lock"
      @timeout = options[:timeout]
      @sleep = options[:sleep]
      @expire = options[:expire]
      @lock_set = options[:lock_set]
      @token = Random.rand(1000000000)
    end

    def key
      @orig_key
    end

    def lock
      if @timeout > 0
        # Blocking mode
        result = false
        start_at = Time.now
        while Time.now - start_at < @timeout
          break if result = try_lock
          sleep @sleep
        end
        result
      else
        # Non-blocking mode
        try_lock
      end
    end

    def try_lock
      now = Time.now.to_i
      @expires_at = now + @expire + 1

      # This script loading is not thread safe (touching a class variable), but
      # that's okay, because the race is harmless.
      @@lock_script_sha ||= Promiscuous::Redis.script(:load, <<-SCRIPT)
        local key = KEYS[1]
        local lock_set = KEYS[2]
        local now = tonumber(ARGV[1])
        local orig_key = ARGV[2]
        local expires_at = tonumber(ARGV[3])
        local token = ARGV[4]
        local old_value = redis.call('get', key)

        if old_value and tonumber(old_value:match("([^:]*):"):rep(1)) > now then return false end
        redis.call('set', key, expires_at .. ':' .. token)
        if lock_set then redis.call('zadd', lock_set, now, orig_key) end

        if old_value then return 'recovered' else return true end
      SCRIPT
      result = Promiscuous::Redis.evalsha(@@lock_script_sha,
                 :keys => [@key, @lock_set], :argv => [now, @orig_key, @expires_at, @token])
      return :recovered if result == 'recovered'
      !!result
    end

    def unlock
      # Since it's possible that the operations in the critical section took a long time,
      # we can't just simply release the lock. The unlock method checks if @expires_at
      # remains the same, and do not release when the lock timestamp was overwritten.

      @@unlock_script_sha ||= Promiscuous::Redis.script(:load, <<-SCRIPT)
        local key = KEYS[1]
        local lock_set = KEYS[2]
        local orig_key = ARGV[1]
        local old_value = ARGV[2]

        if redis.call('get', key) == old_value then
          redis.call('del', key)
          if lock_set then redis.call('zrem', lock_set, orig_key) end
          return true
        else
          return false
        end
      SCRIPT
      Promiscuous::Redis.evalsha(@@unlock_script_sha,
        :keys => [@key, @lock_set], :argv => [@orig_key, "#{@expires_at}:#{@token}"])
    end
  end
end
