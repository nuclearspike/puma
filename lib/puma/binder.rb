# frozen_string_literal: true

require 'uri'
require 'socket'

require_relative 'const'
require_relative 'util'

module Puma

  if HAS_SSL
    require_relative 'minissl'
    require_relative 'minissl/context_builder'
  end

  class Binder
    include Puma::Const

    RACK_VERSION = [1,6].freeze

    # `SO_REUSEPORT` lets several sockets bind the same address. What the kernel
    # then does with an incoming connection is platform specific: Linux spreads
    # connections over the sockets in the group, while Darwin and the BSDs only
    # permit the duplicate bind and hand every new connection to whichever socket
    # bound most recently (measured on arm64-darwin25: four listeners, 200
    # connections, all 200 to the last one to bind). FreeBSD's load balancing
    # variant is a separate option, `SO_REUSEPORT_LB`, absent on Darwin.
    # @version 8.1.0
    HAS_SO_REUSEPORT = ::Socket.const_defined?(:SO_REUSEPORT)

    # Whether `SO_REUSEPORT` on this platform spreads incoming connections over
    # the sockets bound to the address, rather than only permitting the bind.
    # @version 8.1.0
    SO_REUSEPORT_DISTRIBUTES = HAS_SO_REUSEPORT &&
      RbConfig::CONFIG['host_os'].to_s.match?(/linux/i)

    def initialize(log_writer, options, env: ENV)
      @log_writer = log_writer
      @options = options
      @listeners = []
      @inherited_fds = {}
      @activated_sockets = {}
      @unix_paths = []
      @env = env

      @proto_env = {
        "rack.version".freeze => RACK_VERSION,
        "rack.errors".freeze => log_writer.stderr,
        "rack.multithread".freeze => options[:max_threads] > 1,
        "rack.multiprocess".freeze => options[:workers] >= 1,
        "rack.run_once".freeze => false,
        RACK_URL_SCHEME => options[:rack_url_scheme],
        "SCRIPT_NAME".freeze => env['SCRIPT_NAME'] || "",

        # I'd like to set a default CONTENT_TYPE here but some things
        # depend on their not being a default set and inferring
        # it from the content. And so if i set it here, it won't
        # infer properly.

        "QUERY_STRING".freeze => "",
        SERVER_SOFTWARE => PUMA_SERVER_STRING,
        GATEWAY_INTERFACE => CGI_VER,

        RACK_AFTER_REPLY => nil,
        RACK_RESPONSE_FINISHED => nil,
      }

      @envs = {}
      @ios = []

      # Backlog of each TCP listener, keyed by file descriptor, so a worker
      # binding its own `SO_REUSEPORT` socket can reproduce it.
      @tcp_backlogs = {}
      @reuse_port_per_worker = nil
      @reuse_port_listeners = false
    end

    attr_reader :ios

    # @version 5.0.0
    attr_reader :activated_sockets, :envs, :inherited_fds, :listeners, :proto_env, :unix_paths

    # @version 5.0.0
    attr_writer :ios, :listeners

    def env(sock)
      @envs.fetch(sock, @proto_env)
    end

    def close
      @ios.each { |i| i.close }
    end

    # @!attribute [r] connected_ports
    # @version 5.0.0
    def connected_ports
      t = ios.map { |io| io.addr[1] }; t.uniq!; t
    end

    # @version 5.0.0
    def create_inherited_fds(env_hash)
      env_hash.select {|k,v| k =~ /PUMA_INHERIT_\d+/}.each do |_k, v|
        fd, url = v.split(":", 2)
        @inherited_fds[url] = fd.to_i
      end.keys # pass keys back for removal
    end

    # systemd socket activation.
    # LISTEN_FDS = number of listening sockets. e.g. 2 means accept on 2 sockets w/descriptors 3 and 4.
    # LISTEN_PID = PID of the service process, aka us
    # @see https://www.freedesktop.org/software/systemd/man/systemd-socket-activate.html
    # @version 5.0.0
    #
    def create_activated_fds(env_hash)
      @log_writer.debug { "ENV['LISTEN_FDS'] #{@env['LISTEN_FDS'].inspect}  env_hash['LISTEN_PID'] #{env_hash['LISTEN_PID'].inspect}" }
      return [] unless env_hash['LISTEN_FDS'] && env_hash['LISTEN_PID'].to_i == $$
      env_hash['LISTEN_FDS'].to_i.times do |index|
        sock = TCPServer.for_fd(socket_activation_fd(index))
        key = begin # Try to parse as a path
          [:unix, Socket.unpack_sockaddr_un(sock.getsockname)]
        rescue ArgumentError # Try to parse as a port/ip
          port, addr = Socket.unpack_sockaddr_in(sock.getsockname)
          addr = "[#{addr}]" if addr&.include? ':'
          [:tcp, addr, port]
        end
        @activated_sockets[key] = sock
        @log_writer.debug { "Registered #{key.join ':'} for activation from LISTEN_FDS" }
      end
      ["LISTEN_FDS", "LISTEN_PID"] # Signal to remove these keys from ENV
    end

    # Synthesize binds from systemd socket activation
    #
    # When systemd socket activation is enabled, it can be tedious to keep the
    # binds in sync. This method can synthesize any binds based on the received
    # activated sockets. Any existing matching binds will be respected.
    #
    # When only_matching is true in, all binds that do not match an activated
    # socket is removed in place.
    #
    # It's a noop if no activated sockets were received.
    def synthesize_binds_from_activated_fs(binds, only_matching)
      return binds unless activated_sockets.any?

      activated_binds = []

      activated_sockets.keys.each do |proto, addr, port|
        if port
          tcp_url = "#{proto}://#{addr}:#{port}"
          ssl_url = "ssl://#{addr}:#{port}"
          ssl_url_prefix = "#{ssl_url}?"

          existing = binds.find { |bind| bind == tcp_url || bind == ssl_url || bind.start_with?(ssl_url_prefix) }

          activated_binds << (existing || tcp_url)
        else
          # TODO: can there be a SSL bind without a port?
          activated_binds << "#{proto}://#{addr}"
        end
      end

      if only_matching
        activated_binds
      else
        binds | activated_binds
      end
    end

    def before_parse(&block)
      @before_parse ||= []
      @before_parse << block if block
      @before_parse
    end

    def parse(binds, log_writer = nil, log_msg = 'Listening')
      before_parse.each(&:call)
      log_writer ||= @log_writer
      # Resolve, and log, the reuse-port decision once before any listener is
      # created, so it is reported even when no bind reaches `add_tcp_listener`.
      reuse_port_per_worker?
      binds.each do |str|
        uri = URI.parse str
        case uri.scheme
        when "tcp"
          if fd = @inherited_fds.delete(str)
            io = inherit_tcp_listener uri.host, uri.port, fd
            log_writer.log "* Inherited #{str}"
          elsif sock = @activated_sockets.delete([ :tcp, uri.host, uri.port ])
            io = inherit_tcp_listener uri.host, uri.port, sock
            log_writer.log "* Activated #{str}"
          else
            ios_len = @ios.length
            params = Util.parse_query uri.query

            low_latency = params.key?('low_latency') && params['low_latency'] != 'false'
            backlog = params.fetch('backlog', 1024).to_i

            io = add_tcp_listener uri.host, uri.port, low_latency, backlog

            @ios[ios_len..-1].each do |i|
              addr = loc_addr_str i
              log_writer.log "* #{log_msg} on http://#{addr}"
            end
          end

          @listeners << [str, io] if io
        when "unix"
          path = "#{uri.host}#{uri.path}".gsub("%20", " ")
          abstract = false
          if str.start_with? 'unix://@'
            raise "OS does not support abstract UNIXSockets" unless Puma.abstract_unix_socket?
            abstract = true
            path = "@#{path}"
          end

          if fd = @inherited_fds.delete(str)
            @unix_paths << path unless abstract || File.exist?(path)
            io = inherit_unix_listener path, fd
            log_writer.log "* Inherited #{str}"
          elsif sock = @activated_sockets.delete([ :unix, path ]) ||
              !abstract && @activated_sockets.delete([ :unix, File.realdirpath(path) ])
            @unix_paths << path unless abstract || File.exist?(path)
            io = inherit_unix_listener path, sock
            log_writer.log "* Activated #{str}"
          else
            umask = nil
            mode = nil
            backlog = 1024

            if uri.query
              params = Util.parse_query uri.query
              if u = params['umask']
                # Use Integer() to respect the 0 prefix as octal
                umask = Integer(u)
              end

              if u = params['mode']
                mode = Integer('0'+u)
              end

              if u = params['backlog']
                backlog = Integer(u)
              end
            end

            @unix_paths << path unless abstract || File.exist?(path)
            io = add_unix_listener path, umask, mode, backlog
            log_writer.log "* #{log_msg} on #{str}"
          end

          @listeners << [str, io]
        when "ssl"
          cert_key = %w[cert key]

          raise "Puma compiled without SSL support" unless HAS_SSL

          params = Util.parse_query uri.query

          # If key and certs are not defined and localhost gem is required.
          # localhost gem will be used for self signed
          # Load localhost authority if not loaded.
          # Ruby 3 `values_at` accepts an array, earlier do not
          if params.values_at(*cert_key).all? { |v| v.to_s.empty? }
            ctx = localhost_authority && localhost_authority_context
          end

          ctx ||=
            begin
              # Extract cert_pem and key_pem from options[:store] if present
              cert_key.each do |v|
                if params[v]&.start_with?('store:')
                  index = Integer(params.delete(v).split('store:').last)
                  params["#{v}_pem"] = @options[:store][index]
                end
              end
              MiniSSL::ContextBuilder.new(params, @log_writer).context
            end

          if fd = @inherited_fds.delete(str)
            log_writer.log "* Inherited #{str}"
            io = inherit_ssl_listener fd, ctx
          elsif sock = @activated_sockets.delete([ :tcp, uri.host, uri.port ])
            io = inherit_ssl_listener sock, ctx
            log_writer.log "* Activated #{str}"
          else
            ios_len = @ios.length
            backlog = params.fetch('backlog', 1024).to_i
            low_latency = params['low_latency'] != 'false'
            io = add_ssl_listener uri.host, uri.port, ctx, low_latency, backlog

            @ios[ios_len..-1].each do |i|
              addr = loc_addr_str i
              log_writer.log "* #{log_msg} on ssl://#{addr}?#{uri.query}"
            end
          end

          @listeners << [str, io] if io
        else
          log_writer.error "Invalid URI: #{str}"
        end
      end

      # If we inherited fds but didn't use them (because of a
      # configuration change), then be sure to close them.
      @inherited_fds.each do |str, fd|
        log_writer.log "* Closing unused inherited connection: #{str}"

        begin
          IO.for_fd(fd).close
        rescue SystemCallError
        end

        # We have to unlink a unix socket path that's not being used
        uri = URI.parse str
        if uri.scheme == "unix"
          path = "#{uri.host}#{uri.path}"
          File.unlink path
        end
      end

      # Also close any unused activated sockets
      unless @activated_sockets.empty?
        fds = @ios.map(&:to_i)
        @activated_sockets.each do |key, sock|
          next if fds.include? sock.to_i
          log_writer.log "* Closing unused activated socket: #{key.first}://#{key[1..-1].join ':'}"
          begin
            sock.close
          rescue SystemCallError
          end
          # We have to unlink a unix socket path that's not being used
          File.unlink key[1] if key.first == :unix
        end
      end
    end

    def localhost_authority
      @localhost_authority ||= Localhost::Authority.fetch if defined?(Localhost::Authority) && !Puma::IS_JRUBY
    end

    def localhost_authority_context
      return unless localhost_authority

      key_path, crt_path = if [:key_path, :certificate_path].all? { |m| localhost_authority.respond_to?(m) }
        [localhost_authority.key_path, localhost_authority.certificate_path]
      else
        local_certificates_path = File.expand_path("~/.localhost")
        [File.join(local_certificates_path, "localhost.key"), File.join(local_certificates_path, "localhost.crt")]
      end
      MiniSSL::ContextBuilder.new({ "key" => key_path, "cert" => crt_path }, @log_writer).context
    end

    # Tell the server to listen on host +host+, port +port+.
    # If +optimize_for_latency+ is true (the default) then clients connecting
    # will be optimized for latency over throughput.
    #
    # +backlog+ indicates how many unaccepted connections the kernel should
    # allow to accumulate before returning connection refused.
    #
    def add_tcp_listener(host, port, optimize_for_latency=true, backlog=1024)
      if host == "localhost"
        loopback_addresses.each do |addr|
          add_tcp_listener addr, port, optimize_for_latency, backlog
        end
        return
      end

      host = host[1..-2] if host&.start_with? '['

      if reuse_port_per_worker?
        # Reserve the address, and prove it can be bound, without listening on
        # it: the workers own the listening sockets in this mode, and a listening
        # socket here would be one more member of the reuse-port group that
        # nothing ever calls accept on.
        tcp_server = reuse_port_tcp_server host, port, optimize_for_latency, backlog: nil
      else
        tcp_server = TCPServer.new(host, port)

        if optimize_for_latency
          tcp_server.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        end
        tcp_server.setsockopt(Socket::SOL_SOCKET,Socket::SO_REUSEADDR, true)
        tcp_server.listen backlog
      end

      @tcp_backlogs[tcp_server.to_i] = backlog
      @ios << tcp_server
      tcp_server
    end

    def inherit_tcp_listener(host, port, fd)
      s = fd.kind_of?(::TCPServer) ? fd : ::TCPServer.for_fd(fd)

      # A socket inherited from a master that was running with
      # `reuse_port_per_worker` is bound but not listening. If this process is
      # not in that mode nothing else is going to listen on it.
      s.listen 1024 if !reuse_port_per_worker? && not_listening?(s)

      @ios << s
      s
    end

    # Should this process create per-worker `SO_REUSEPORT` listeners rather than
    # share the single socket the master binds? Resolved once per process; a
    # worker inherits the answer, and the fact that any warning was already
    # logged, through `fork`.
    #
    # @version 8.1.0
    def reuse_port_per_worker?
      return @reuse_port_per_worker unless @reuse_port_per_worker.nil?

      requested = @options[:reuse_port_per_worker]

      @reuse_port_per_worker =
        if !requested || @options.fetch(:workers, 0) < 1
          false
        elsif !HAS_SO_REUSEPORT
          reuse_port_unavailable "this platform has no SO_REUSEPORT"
        elsif !SO_REUSEPORT_DISTRIBUTES && requested != :force
          reuse_port_unavailable "SO_REUSEPORT on #{RbConfig::CONFIG['host_os']} " \
            "hands every new connection to the socket that bound most recently " \
            "instead of spreading them, so one worker would serve all traffic"
        else
          @log_writer.log "* Per-worker SO_REUSEPORT listeners: each worker binds its own socket"
          true
        end
    end

    # True once this process has replaced its inherited TCP listeners with its
    # own `SO_REUSEPORT` sockets.
    #
    # @version 8.1.0
    def reuse_port_listeners?
      @reuse_port_listeners
    end

    # Replace every inherited TCP listener with one this process binds itself,
    # with `SO_REUSEPORT`, on the same address and port, then close the inherited
    # descriptor so this process no longer shares the master's accept queue.
    # Called by each cluster worker before it starts its server.
    #
    # SSL and UNIX listeners are left alone and keep the inherited socket.
    #
    # Every replacement is bound before any inherited socket is closed, and a
    # failure part way through closes the replacements it did bind, so this
    # process is left with exactly the working listeners it started with.
    #
    # Call this before the server starts. It swaps entries in {#ios} and
    # {#listeners} in place, which is only safe while nothing is accepting.
    #
    # @return [Integer] number of listeners replaced
    # @version 8.1.0
    def rebind_tcp_listeners_for_reuse_port
      return 0 unless reuse_port_per_worker?

      bound = []

      rebound =
        begin
          @ios.grep(::TCPServer).map do |old_io|
            addr    = old_io.local_address
            backlog = @tcp_backlogs[old_io.to_i] || 1024
            new_io  = reuse_port_tcp_server addr.ip_address, addr.ip_port,
              tcp_nodelay?(old_io), backlog: backlog
            bound << new_io
            [old_io, new_io, backlog]
          end
        rescue Exception
          bound.each { |io| io.close rescue nil }
          raise
        end

      return 0 if rebound.empty?

      @tcp_backlogs = {}

      rebound.each do |old_io, new_io, backlog|
        @tcp_backlogs[new_io.to_i] = backlog
        @envs[new_io] = @envs.delete(old_io) if @envs.key?(old_io)
        @listeners.each { |listener| listener[1] = new_io if listener[1].equal?(old_io) }
        @ios[@ios.index(old_io)] = new_io

        begin
          old_io.close
        rescue SystemCallError, IOError
        end
      end

      @reuse_port_listeners = true
      rebound.size
    end

    def add_ssl_listener(host, port, ctx,
                         optimize_for_latency=true, backlog=1024)

      raise "Puma compiled without SSL support" unless HAS_SSL
      # Puma will try to use local authority context if context is supplied nil
      ctx ||= localhost_authority_context

      if host == "localhost"
        loopback_addresses.each do |addr|
          add_ssl_listener addr, port, ctx, optimize_for_latency, backlog
        end
        return
      end

      host = host[1..-2] if host&.start_with? '['
      s = TCPServer.new(host, port)
      if optimize_for_latency
        s.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      end
      s.setsockopt(Socket::SOL_SOCKET,Socket::SO_REUSEADDR, true)
      s.listen backlog

      ssl = MiniSSL::Server.new s, ctx
      env = @proto_env.dup
      env[HTTPS_KEY] = HTTPS
      @envs[ssl] = env

      @ios << ssl
      s
    end

    def inherit_ssl_listener(fd, ctx)
      raise "Puma compiled without SSL support" unless HAS_SSL
      # Puma will try to use local authority context if context is supplied nil
      ctx ||= localhost_authority_context

      s = fd.kind_of?(::TCPServer) ? fd : ::TCPServer.for_fd(fd)

      ssl = MiniSSL::Server.new(s, ctx)

      env = @proto_env.dup
      env[HTTPS_KEY] = HTTPS
      @envs[ssl] = env

      @ios << ssl

      s
    end

    # Tell the server to listen on +path+ as a UNIX domain socket.
    #
    def add_unix_listener(path, umask=nil, mode=nil, backlog=1024)
      # Let anyone connect by default
      umask ||= 0

      begin
        old_mask = File.umask(umask)

        if File.exist? path
          begin
            old = UNIXSocket.new path
          rescue SystemCallError, IOError
            File.unlink path
          else
            old.close
            raise "There is already a server bound to: #{path}"
          end
        end
        s = UNIXServer.new path.sub(/\A@/, "\0") # check for abstract UNIXSocket
        s.listen backlog
        @ios << s
      ensure
        File.umask old_mask
      end

      if mode
        File.chmod mode, path
      end

      env = @proto_env.dup
      env[REMOTE_ADDR] = "127.0.0.1"
      @envs[s] = env

      s
    end

    def inherit_unix_listener(path, fd)
      s = fd.kind_of?(::TCPServer) ? fd : ::UNIXServer.for_fd(fd)

      @ios << s

      env = @proto_env.dup
      env[REMOTE_ADDR] = "127.0.0.1"
      @envs[s] = env

      s
    end

    def close_listeners
      @listeners.each do |l, io|
        begin
          io.close unless io.closed?
          uri = URI.parse l
          next unless uri.scheme == 'unix'
          unix_path = "#{uri.host}#{uri.path}"
          File.unlink unix_path if @unix_paths.include?(unix_path) && File.exist?(unix_path)
        rescue Errno::EBADF
        end
      end
    end

    def redirects_for_restart
      redirects = @listeners.map { |a| [a[1].to_i, a[1].to_i] }.to_h
      redirects[:close_others] = true
      redirects
    end

    # @version 5.0.0
    def redirects_for_restart_env
      @listeners.each_with_object({}).with_index do |(listen, memo), i|
        memo["PUMA_INHERIT_#{i}"] = "#{listen[1].to_i}:#{listen[0]}"
      end
    end

    private

    # Create a `TCPServer` with `SO_REUSEPORT` set *before* the bind, which is
    # required rather than incidental: unless the first socket bound to an
    # address carries the option, every later bind of that address fails with
    # `EADDRINUSE`.
    #
    # A nil +backlog+ binds without listening.
    #
    # @version 8.1.0
    def reuse_port_tcp_server(host, port, optimize_for_latency, backlog:)
      error = nil

      # AI_PASSIVE so a nil or empty host resolves to the wildcard address, which
      # is what `TCPServer.new` does with the same argument.
      Addrinfo.getaddrinfo(host, port, nil, :STREAM, nil, Socket::AI_PASSIVE).each do |ai|
        sock = Socket.new ai.pfamily, ai.socktype, ai.protocol

        begin
          sock.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) if optimize_for_latency
          sock.setsockopt Socket::SOL_SOCKET, Socket::SO_REUSEADDR, true
          sock.setsockopt Socket::SOL_SOCKET, Socket::SO_REUSEPORT, true
          sock.bind ai
          sock.listen backlog if backlog
        rescue SystemCallError => e
          error = e
          sock.close rescue nil
          next
        end

        # Hand the descriptor over: the rest of Puma accepts from these and needs
        # `TCPServer#accept_nonblock`, which returns a TCPSocket, rather than
        # `Socket#accept_nonblock`, which returns a [Socket, Addrinfo] pair.
        tcp_server = ::TCPServer.for_fd sock.fileno
        sock.autoclose = false
        return tcp_server
      end

      raise error || Errno::EADDRNOTAVAIL.new("#{host}:#{port}")
    end

    # @version 8.1.0
    def tcp_nodelay?(io)
      io.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY).bool
    rescue SystemCallError
      true
    end

    # Only true when the socket can be proven not to be listening, so that an
    # inherited socket is never touched on a guess -- calling `listen` again
    # would silently reset the backlog it was created with.
    #
    # Darwin does not answer `SO_ACCEPTCONN`, so there this is always false. A
    # hot restart out of `reuse_port_per_worker` on Darwin therefore inherits a
    # socket nothing listens on; that needs `:force`, which is documented as a
    # measurement mode rather than one to run under.
    #
    # @version 8.1.0
    def not_listening?(io)
      return false unless Socket.const_defined?(:SO_ACCEPTCONN)
      !io.getsockopt(Socket::SOL_SOCKET, Socket::SO_ACCEPTCONN).bool
    rescue SystemCallError
      false
    end

    # @version 8.1.0
    def reuse_port_unavailable(reason)
      @log_writer.log "! WARNING: `reuse_port_per_worker` is set but #{reason}."
      @log_writer.log "! Falling back to the listener inherited from the master."
      false
    end

    # @!attribute [r] loopback_addresses
    def loopback_addresses
      t = Socket.ip_address_list.select do |addrinfo|
        addrinfo.ipv6_loopback? || addrinfo.ipv4_loopback?
      end
      t.map! { |addrinfo| addrinfo.ip_address }; t.uniq!; t
    end

    def loc_addr_str(io)
      loc_addr = io.to_io.local_address
      if loc_addr.ipv6?
        "[#{loc_addr.ip_unpack[0]}]:#{loc_addr.ip_unpack[1]}"
      else
        loc_addr.ip_unpack.join(':')
      end
    end

    # @version 5.0.0
    def socket_activation_fd(int)
      int + 3 # 3 is the magic number you add to follow the SA protocol
    end
  end
end
