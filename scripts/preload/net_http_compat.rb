# Net::HTTP facade for Ruby VMs without the real network stdlib.
#
# Ruby 1.8 / 1.9 can't link the era openssl C ext against our
# OpenSSL (1.1.x broke the API those exts were written for), so
# `require 'net/http'` + `use_ssl` can never work natively there.
# Desktop-targeting game scripts (updaters, version pings,
# telemetry) overwhelmingly use a small slice of the Net::HTTP API,
# so provide that slice backed by the engine's native HTTPLite
# client, which speaks both http and https with real certificate
# verification.
#
# Generic by design: implements documented Net::HTTP surface only,
# no game-specific branches. Not loaded on Ruby >= 2.0 (those VMs
# get the genuine stdlib). Installed regardless of the network
# toggle: with networking off the device behaves like airplane mode
# - the classes exist, and requests fail with rescuable connection
# errors when the native client refuses them.
#
# The facade class itself binds to the `Net::HTTP` constant LAZILY,
# through `Net.const_missing`. Berka's downloader (Pokemon Daybreak
# and friends) declares `module Net; module HTTP` at script load.
# With an eagerly defined class in place, that declaration dies with
# "HTTP is not a module" (TypeError). Lazy binding lets a game that
# defines its own Net::HTTP own the constant, while a game that
# only references Net::HTTP gets the facade on first use. The cost:
# `defined?(Net::HTTP)` is nil until the first real reference, so
# feature probes see it as absent - no known 1.8/1.9 game does
# that, they all call it directly.
#
# Deliberate deviations from real Net::HTTP, all on the "keep old
# games running" side:
# - One-shot connections: `start` doesn't hold a socket open.
#   Each request is an independent native call.
# - `read_body` with a block yields the whole body as one chunk
#   (the native client buffers, per-chunk streaming isn't worth the
#   C plumbing for progress-bar use cases - HTTPLite.download covers
#   real streaming).
# - Timeout setters store their value but the native client's own
#   timeouts (10s connect / 30s read) are what actually apply.
# - `verify_mode=` is accepted and ignored: verification is always
#   on, against the host CA bundle. VERIFY_NONE does not disable
#   it - fail closed, not open.

if RUBY_VERSION < '2' && defined?(HTTPLite)

  module Net
    class HTTPResponse
      attr_reader :code, :message, :body

      def initialize(status, body, headers)
        @code = status.to_s
        @message = HTTPResponse.status_message(status)
        @body = body
        @headers = {}
        (headers || {}).each { |k, v| @headers[k.to_s.downcase] = v.to_s }
      end

      def self.status_message(status)
        {
          200 => 'OK', 201 => 'Created', 204 => 'No Content',
          301 => 'Moved Permanently', 302 => 'Found', 304 => 'Not Modified',
          400 => 'Bad Request', 401 => 'Unauthorized', 403 => 'Forbidden',
          404 => 'Not Found', 500 => 'Internal Server Error',
          502 => 'Bad Gateway', 503 => 'Service Unavailable'
        }[status] || ''
      end

      def [](key)
        @headers[key.to_s.downcase]
      end

      def key?(key)
        @headers.key?(key.to_s.downcase)
      end

      def each_header(&block)
        @headers.each(&block)
      end
      alias each each_header

      def to_hash
        hash = {}
        @headers.each { |k, v| hash[k] = [v] }
        hash
      end

      def read_body
        yield @body if block_given? && @body && !@body.empty?
        @body
      end

      def entity
        @body
      end

      def content_length
        len = self['content-length']
        len && len.to_i
      end

      def content_type
        ctype = self['content-type']
        ctype && ctype.split(';').first
      end

      # `value` raises on non-2xx like the real thing. Games use it
      # as a quick "did this work" assert.
      def value
        return nil if code_type_success?

        raise Net::HTTPError.new("#{@code} #{@message}", self)
      end

      def code_type_success?
        @code.length == 3 && @code[0, 1] == '2'
      end
      private :code_type_success?

      # Emulate the response class tree far enough for the
      # ubiquitous `case res when Net::HTTPSuccess` pattern:
      # is_a? consults the status code instead of the class.
      # (Built lazily: the marker classes are defined below.)
      def self.status_range_for(klass)
        @status_ranges ||= {
          Net::HTTPSuccess => 200..299,
          Net::HTTPRedirection => 300..399,
          Net::HTTPClientError => 400..499,
          Net::HTTPServerError => 500..599,
          Net::HTTPOK => 200..200,
          Net::HTTPNotFound => 404..404,
          Net::HTTPUnauthorized => 401..401
        }
        @status_ranges[klass]
      end

      def is_a?(klass)
        range = HTTPResponse.status_range_for(klass)
        return super if range.nil?

        range.include?(@code.to_i)
      end
      alias kind_of? is_a?
    end

    # Marker classes for is_a? dispatch above. Games never
    # instantiate these. Responses are always Net::HTTPResponse.
    class HTTPSuccess < HTTPResponse; end
    class HTTPOK < HTTPSuccess; end
    class HTTPRedirection < HTTPResponse; end
    class HTTPClientError < HTTPResponse; end
    class HTTPUnauthorized < HTTPClientError; end
    class HTTPNotFound < HTTPClientError; end
    class HTTPServerError < HTTPResponse; end

    class HTTPError < StandardError
      attr_reader :response

      def initialize(message, response = nil)
        super(message)
        @response = response
      end
    end
    HTTPBadResponse = HTTPError
    class ReadTimeout < HTTPError; end unless defined?(ReadTimeout)
    class OpenTimeout < HTTPError; end unless defined?(OpenTimeout)

    class HTTPRequestBase
      attr_reader :method, :path
      attr_accessor :body

      def initialize(method, path, initheader = nil)
        @method = method
        @path = path
        @headers = {}
        (initheader || {}).each { |k, v| @headers[k.to_s] = v.to_s }
        @body = nil
      end

      def []=(key, value)
        @headers[key.to_s] = value.to_s
      end

      def [](key)
        match = @headers.keys.find { |k| k.downcase == key.to_s.downcase }
        match && @headers[match]
      end

      def basic_auth(user, password)
        # pack('m') is base64. Strip the newlines pack inserts.
        encoded = ["#{user}:#{password}"].pack('m').delete("\n")
        @headers['Authorization'] = "Basic #{encoded}"
      end

      def set_form_data(params, _sep = '&')
        pairs = params.map { |k, v| "#{HTTPFacade.url_encode(k.to_s)}=#{HTTPFacade.url_encode(v.to_s)}" }
        @body = pairs.join('&')
        @headers['Content-Type'] = 'application/x-www-form-urlencoded'
      end
      alias form_data= set_form_data

      def content_type=(ctype)
        @headers['Content-Type'] = ctype
      end

      def headers_hash
        @headers
      end
    end

    # The Net::HTTP facade. Defined under a non-colliding name and
    # bound to the `HTTP` constant lazily via Net.const_missing
    # below - see the header comment.
    class HTTPFacade
      class Get < HTTPRequestBase
        def initialize(path, initheader = nil)
          super('GET', path, initheader)
        end
      end

      class Post < HTTPRequestBase
        def initialize(path, initheader = nil)
          super('POST', path, initheader)
        end
      end

      class Head < HTTPRequestBase
        def initialize(path, initheader = nil)
          super('HEAD', path, initheader)
        end
      end

      attr_reader :address, :port
      attr_accessor :open_timeout, :read_timeout, :use_ssl, :verify_mode

      def initialize(address, port = nil)
        @address = address
        @port = port
        @use_ssl = false
        @started = false
        @open_timeout = nil
        @read_timeout = nil
        @verify_mode = nil
      end

      def use_ssl=(flag)
        @use_ssl = !!flag
      end

      def use_ssl?
        @use_ssl
      end

      def start
        @started = true
        if block_given?
          begin
            return yield(self)
          ensure
            @started = false
          end
        end
        self
      end

      def started?
        @started
      end

      def finish
        @started = false
        nil
      end

      def get(path, initheader = nil)
        request(Get.new(path, initheader))
      end

      def head(path, initheader = nil)
        request(Head.new(path, initheader))
      end

      def post(path, body, initheader = nil)
        req = Post.new(path, initheader)
        req.body = body
        request(req)
      end

      def request_get(path, initheader = nil, &block)
        res = get(path, initheader)
        block.call(res) if block
        res
      end

      def request_post(path, body, initheader = nil, &block)
        res = post(path, body, initheader)
        block.call(res) if block
        res
      end

      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      # -- deliberately linear dispatch mirroring Net::HTTP's public contract
      def request(req, body = nil)
        req.body = body if body
        url = _build_url(req.path)

        # Use the unwrapped native methods: http_compat.rb's
        # JoiPlay-compat wrappers turn every transport failure into a
        # benign empty response, but Net::HTTP callers expect
        # connection and TLS failures to RAISE (games rescue them).
        # Re-raise TLS verification failures under the stub SSLError
        # class for desktop-compatible rescue clauses.
        begin
          result =
            case req.method
            when 'POST'
              if req.body
                ctype = req['Content-Type'] || 'application/x-www-form-urlencoded'
                HTTPLite.send(_native_method(:post_body), url, req.body, ctype, req.headers_hash)
              else
                HTTPLite.send(_native_method(:post), url, {}, req.headers_hash)
              end
            else
              # HEAD is served as GET: cpp-httplib discards nothing for
              # us, but callers only read status/headers anyway.
              HTTPLite.send(_native_method(:get), url, req.headers_hash)
            end
        rescue Exception => e # rubocop:disable Lint/RescueException -- MKXPError is not a StandardError
          raise unless e.is_a?(StandardError) || (defined?(MKXPError) && e.is_a?(MKXPError))
          raise OpenSSL::SSL::SSLError, e.message if e.message.to_s =~ /SSL/i
          raise Net::HTTPError.new(e.message, nil) unless e.is_a?(StandardError)

          raise
        end

        raise Net::HTTPError.new("bad response for #{url}", nil) unless result.is_a?(Hash)
        raise Net::HTTPError.new("connection to #{url} failed", nil) if result[:status].to_i.zero?

        res = HTTPResponse.new(result[:status].to_i, result[:body].to_s, result[:headers])
        yield res if block_given?
        res
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      def _native_method(name)
        native = :"__mkxp_native_#{name}"
        HTTPLite.respond_to?(native) ? native : name
      end
      private :_native_method

      def _build_url(path)
        scheme = @use_ssl ? 'https' : 'http'
        default_port = @use_ssl ? 443 : 80
        host_port = @port.nil? || @port.to_i == default_port ? @address : "#{@address}:#{@port}"
        path = "/#{path}" unless path.to_s[0, 1] == '/'
        "#{scheme}://#{host_port}#{path}"
      end
      private :_build_url

      class << self
        def default_port
          80
        end

        def https_default_port
          443
        end

        def start(address, port = nil, *legacy_args)
          http = new(address, port)
          # Ruby 2+ style: Net::HTTP.start(host, port, use_ssl: true).
          # Old-style positional p_addr etc. are ignored (no proxy
          # support), but a trailing options hash is honored.
          opts = legacy_args.last
          http.use_ssl = true if opts.is_a?(Hash) && opts[:use_ssl]
          http.use_ssl = true if port.to_i == 443
          if block_given?
            http.start { |h| return yield(h) }
          else
            http.start
          end
        end

        # Net::HTTP.get(uri) / Net::HTTP.get(host, path[, port]) -> body
        def get(arg1, arg2 = nil, arg3 = nil)
          get_response(arg1, arg2, arg3).body
        end

        # Net::HTTP.get_response(uri) / (host, path[, port]) -> response
        def get_response(arg1, arg2 = nil, arg3 = nil)
          if arg2.nil? && arg1.respond_to?(:host)
            uri = arg1
            http = new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == 'https')
            path = uri.path.to_s.empty? ? '/' : uri.path
            path = "#{path}?#{uri.query}" if uri.respond_to?(:query) && uri.query
            http.get(path)
          else
            http = new(arg1, arg3)
            http.get(arg2 || '/')
          end
        end

        def post_form(uri, params)
          http = new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == 'https')
          req = Post.new(uri.path.to_s.empty? ? '/' : uri.path)
          req.set_form_data(params || {})
          http.request(req)
        end
      end

      def self.url_encode(str)
        str.to_s.gsub(/[^a-zA-Z0-9_.-]/) do |ch|
          format('%%%02X', ch.unpack('C').first)
        end
      end
    end

    # Alias tree some scripts reference directly.
    HTTPGenericRequest = HTTPRequestBase

    # Lazy binding for the HTTP constant: first real reference
    # installs the facade. A game-defined `module Net; module HTTP`
    # never triggers const_missing and simply owns the constant.
    # Everything else falls through to the global stub hook in
    # platform_compat.rb.
    def self.const_missing(name)
      return const_set(:HTTP, HTTPFacade) if name == :HTTP

      super
    end
  end

  # Games rescue SocketError on connection failures. Define it when
  # the socket ext isn't registered so those rescue clauses resolve
  # to a real exception class instead of a const_missing stub.
  class SocketError < StandardError; end unless defined?(SocketError)

  # `require 'openssl'` callers only ever touch the verify-mode
  # constants in the code paths this shim serves.
  unless defined?(OpenSSL)
    module OpenSSL
      module SSL
        VERIFY_NONE = 0
        VERIFY_PEER = 1

        class SSLError < StandardError; end
      end

      class OpenSSLError < StandardError; end
    end
  end

  # These VMs have no real openssl ext (the era exts predate
  # OpenSSL 3 and cannot build). The engine's MKXPCrypto binding
  # exposes libcrypto's EVP one-shots instead. This facade builds
  # the familiar OpenSSL::Cipher / Digest / HMAC / PKCS5 / Random
  # API on top so crypto-dependent game code (rubyzip-AES updaters,
  # HMAC-signed APIs) runs identically on every VM. Without the
  # native module (an older engine core), the classes raise loudly
  # instead of resolving through the always-truthy NullStub
  # const_missing hook and returning garbage.
  if defined?(MKXPCrypto)
    module OpenSSL
      module MKXPCryptoSupport
        def self.digest_name(arg)
          name = if arg.respond_to?(:name)
                   arg.name
                 else
                   arg.to_s
                 end
          name = name.sub(/\AOpenSSL::Digest::/, '')
          raise OpenSSL::OpenSSLError, "unsupported digest #{name}" unless MKXPCrypto.digest_supported?(name)

          name
        end

        def self.hex(str)
          str.unpack('H*')[0]
        end
      end

      class Digest
        attr_reader :name

        def initialize(name, data = nil)
          @name = OpenSSL::MKXPCryptoSupport.digest_name(name)
          @buffer = ''
          update(data) if data
        end

        def update(data)
          @buffer << data.to_s
          self
        end
        alias << update

        def reset
          @buffer = ''
          self
        end

        def digest
          MKXPCrypto.digest(@name, @buffer)
        end

        def hexdigest
          OpenSSL::MKXPCryptoSupport.hex(digest)
        end
        alias to_s hexdigest

        def self.digest(name, data)
          MKXPCrypto.digest(OpenSSL::MKXPCryptoSupport.digest_name(name), data)
        end

        def self.hexdigest(name, data)
          OpenSSL::MKXPCryptoSupport.hex(digest(name, data))
        end

        # OpenSSL::Digest::SHA256.new / .hexdigest(data) spellings.
        # Generated through class_eval STRINGS on purpose: on Ruby
        # 1.8, `super` inside define_method raises at call time,
        # and block-parameter closures share one variable across
        # iterations - every subclass would compute the LAST
        # algorithm in the list. String-eval defines real methods
        # with the name baked in, which behaves identically on
        # every VM.
        %w[MD5 SHA1 SHA224 SHA256 SHA384 SHA512 RIPEMD160].each do |algo|
          subclass = Class.new(self)
          # rubocop:disable Style/DocumentDynamicEvalDefinition
          # Interpolated appearance, for SHA256:
          #   def initialize(data = nil) super('SHA256', data) end
          #   def self.digest(data) MKXPCrypto.digest('SHA256', data) end
          #   def self.hexdigest(data) ...hex(...digest('SHA256', data)) end
          subclass.class_eval(<<-RUBY_EVAL, __FILE__, __LINE__ + 1)
            def initialize(data = nil)
              super('#{algo}', data)
            end

            def self.digest(data)
              MKXPCrypto.digest('#{algo}', data)
            end

            def self.hexdigest(data)
              OpenSSL::MKXPCryptoSupport.hex(MKXPCrypto.digest('#{algo}', data))
            end
          RUBY_EVAL
          # rubocop:enable Style/DocumentDynamicEvalDefinition
          const_set(algo, subclass)
        end
      end

      class HMAC
        def initialize(key, digest)
          @key = key.to_s
          @name = OpenSSL::MKXPCryptoSupport.digest_name(digest)
          @buffer = ''
        end

        def update(data)
          @buffer << data.to_s
          self
        end
        alias << update

        def digest
          MKXPCrypto.hmac(@name, @key, @buffer)
        end

        def hexdigest
          OpenSSL::MKXPCryptoSupport.hex(digest)
        end

        def self.digest(digest, key, data)
          MKXPCrypto.hmac(OpenSSL::MKXPCryptoSupport.digest_name(digest), key.to_s, data.to_s)
        end

        def self.hexdigest(digest, key, data)
          OpenSSL::MKXPCryptoSupport.hex(self.digest(digest, key, data))
        end
      end

      module PKCS5
        def self.pbkdf2_hmac(pass, salt, iterations, key_length, digest)
          MKXPCrypto.pbkdf2_hmac(
            pass.to_s, salt.to_s, iterations, key_length,
            OpenSSL::MKXPCryptoSupport.digest_name(digest)
          )
        end

        def self.pbkdf2_hmac_sha1(pass, salt, iterations, key_length)
          pbkdf2_hmac(pass, salt, iterations, key_length, 'SHA1')
        end
      end

      module Random
        def self.random_bytes(count)
          MKXPCrypto.random_bytes(count)
        end
      end

      class Cipher
        class CipherError < OpenSSL::OpenSSLError; end

        # One-shot backend: update() buffers and final() transforms.
        # Identical bytes to incremental EVP output for the modes
        # games use (CBC/CTR/ECB/CFB/OFB). AEAD modes need tag
        # plumbing this facade does not pretend to have.
        def initialize(name)
          @name = name.to_s.upcase
          if @name =~ /GCM|CCM|OCB|POLY1305|CHACHA/
            raise NotImplementedError,
                  "AEAD cipher #{@name} is not supported here"
          end
          raise CipherError, "unsupported cipher #{@name}" unless MKXPCrypto.cipher_supported?(@name)

          @encrypt = true
          @key = nil
          @iv = ''
          @padding = true
          @buffer = ''
        end

        def encrypt(*_args)
          @encrypt = true
          @buffer = ''
          self
        end

        def decrypt(*_args)
          @encrypt = false
          @buffer = ''
          self
        end

        def key=(value)
          @key = value.to_s
        end

        def iv=(value)
          @iv = value.to_s
        end

        def padding=(value)
          @padding = ![0, false].include?(value)
        end

        def key_len
          MKXPCrypto.cipher_key_length(@name)
        end

        def iv_len
          MKXPCrypto.cipher_iv_length(@name)
        end

        def block_size
          # Good enough for the buffer-sizing games do. EVP block
          # size differs only for stream modes where callers never
          # depend on it.
          16
        end

        def random_key
          key = MKXPCrypto.random_bytes(key_len)
          @key = key
          key
        end

        def random_iv
          iv = MKXPCrypto.random_bytes(iv_len)
          @iv = iv
          iv
        end

        def update(data)
          @buffer << data.to_s
          ''
        end
        alias << update

        def final
          raise CipherError, 'no key set' if @key.nil?

          out = MKXPCrypto.cipher_run(
            @name, @encrypt, @key, @iv, @buffer, @padding
          )
          @buffer = ''
          out
        rescue RuntimeError => e
          raise CipherError, e.message
        end

        def reset
          @buffer = ''
          self
        end

        attr_reader :name

        # OpenSSL::Cipher::AES256.new(:CBC) / AES.new(128, :CTR)
        # spellings used by vendored rubyzip and era scripts.
        class AES < Cipher
          def initialize(bits, mode)
            super("AES-#{bits}-#{mode.to_s.upcase}")
          end
        end

        # String-eval for the same 1.8 super/closure reasons as the
        # Digest subclasses above.
        [128, 192, 256].each do |bits|
          subclass = Class.new(Cipher)
          # rubocop:disable Style/DocumentDynamicEvalDefinition
          # Interpolated appearance, for 256:
          #   def initialize(mode) super("AES-256-#{mode.to_s.upcase}") end
          subclass.class_eval(<<-RUBY_EVAL, __FILE__, __LINE__ + 1)
            def initialize(mode)
              super("AES-#{bits}-\#{mode.to_s.upcase}")
            end
          RUBY_EVAL
          # rubocop:enable Style/DocumentDynamicEvalDefinition
          const_set("AES#{bits}", subclass)
        end
      end
    end
  else
    module OpenSSL
      class Cipher
        def initialize(*_args)
          raise NotImplementedError,
                'OpenSSL::Cipher needs an engine core with MKXPCrypto'
        end
      end

      class Digest
        def initialize(*_args)
          raise NotImplementedError,
                'OpenSSL::Digest needs an engine core with MKXPCrypto ' \
                '(Digest::MD5 / Digest::SHA1 are available)'
        end
      end

      class HMAC
        def initialize(*_args)
          raise NotImplementedError,
                'OpenSSL::HMAC needs an engine core with MKXPCrypto'
        end

        def self.hexdigest(*_args)
          raise NotImplementedError,
                'OpenSSL::HMAC needs an engine core with MKXPCrypto'
        end

        def self.digest(*_args)
          raise NotImplementedError,
                'OpenSSL::HMAC needs an engine core with MKXPCrypto'
        end
      end
    end
  end

  # open-uri facade. The era stdlib does not ship open-uri, but
  # 2010s scripts lean on `open('http://...')` and
  # `URI.parse(url).read` for version checks and small fetches.
  # Both shapes ride HTTPLite here. The result quacks like
  # open-uri's StringIO: read/each_line plus status, base_uri, and
  # meta. Non-URL arguments fall through to the real Kernel#open
  # untouched.
  module MKXPOpenURI
    def self.fetch(url)
      response = begin
        HTTPLite.get(url, nil, true)
      rescue StandardError
        nil
      end
      status = response.is_a?(Hash) ? response[:status].to_i : 0
      raise Errno::ENETDOWN, url.to_s if status.zero?

      io = StringIO.new(response[:body].to_s)
      headers = {}
      (response[:headers] || {}).each { |k, v| headers[k.to_s.downcase] = v.to_s }
      singleton = class << io; self; end
      singleton.send(:define_method, :status) { [status.to_s, ''] }
      singleton.send(:define_method, :base_uri) { url }
      singleton.send(:define_method, :meta) { headers }
      singleton.send(:define_method, :content_type) { headers['content-type'].to_s }
      io
    end

    def self.url?(value)
      value.is_a?(String) && value =~ %r{\Ahttps?://}
    end
  end

  module Kernel
    alias _mkxp_pre_openuri_open open

    def open(name, *rest, &block)
      return _mkxp_pre_openuri_open(name, *rest, &block) unless MKXPOpenURI.url?(name)

      io = MKXPOpenURI.fetch(name)
      return io unless block

      begin
        yield io
      ensure
        io.close
      end
    end
    module_function :open
  end

  if defined?(URI)
    def URI.open(name, *rest, &block)
      Kernel.open(name.to_s, *rest, &block)
    end

    if defined?(URI::Generic) && !URI::Generic.method_defined?(:read)
      module URI
        class Generic
          def read(*_rest)
            io = MKXPOpenURI.fetch(to_s)
            begin
              io.read
            ensure
              io.close
            end
          end

          def open(*rest, &block)
            Kernel.open(to_s, *rest, &block)
          end
        end
      end
    end
  end

  # Mark the stdlib entry points as loaded so a later
  # `require 'net/http'` (or the era stdlib shipping in a game's own
  # load path) doesn't load over this facade. Cover both spellings:
  # 1.8 stores whatever string require resolved.
  ['net/http', 'net/https', 'net/protocol', 'openssl', 'open-uri'].each do |feature|
    [feature, "#{feature}.rb"].each do |name|
      $LOADED_FEATURES << name unless $LOADED_FEATURES.include?(name)
    end
  end

  if defined?(MKXP) && MKXP.respond_to?(:puts)
    MKXP.puts('[net_http_compat] Net::HTTP facade over HTTPLite installed (lazy bind)')
  end
end
