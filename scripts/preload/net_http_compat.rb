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
# Deliberate deviations from real Net::HTTP, all on the "keep old
# games running" side:
# - One-shot connections: `start` doesn't hold a socket open;
#   each request is an independent native call.
# - `read_body` with a block yields the whole body as one chunk
#   (the native client buffers; per-chunk streaming isn't worth the
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

      # `value` raises on non-2xx like the real thing; games use it
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
    # instantiate these; responses are always Net::HTTPResponse.
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
        # pack('m') is base64; strip the newlines pack inserts.
        encoded = ["#{user}:#{password}"].pack('m').delete("\n")
        @headers['Authorization'] = "Basic #{encoded}"
      end

      def set_form_data(params, _sep = '&')
        @body = params.map { |k, v| "#{HTTP.url_encode(k.to_s)}=#{HTTP.url_encode(v.to_s)}" }.join('&')
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

    class HTTP
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
  end

  # Games rescue SocketError on connection failures; define it when
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
    end
  end

  # Mark the stdlib entry points as loaded so a later
  # `require 'net/http'` (or the era stdlib shipping in a game's own
  # load path) doesn't load over this facade. Cover both spellings:
  # 1.8 stores whatever string require resolved.
  ['net/http', 'net/https', 'net/protocol', 'openssl'].each do |feature|
    [feature, "#{feature}.rb"].each do |name|
      $LOADED_FEATURES << name unless $LOADED_FEATURES.include?(name)
    end
  end

  if defined?(MKXP) && MKXP.respond_to?(:puts)
    MKXP.puts('[net_http_compat] Net::HTTP facade over HTTPLite installed')
  end
end
