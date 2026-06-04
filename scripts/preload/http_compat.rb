# JoiPlay-style HTTP module shim.
#
# JoiPlay's C++ binding exposes an `HTTP` module with
# `HTTP.get(host, query)`, `HTTP.post(host, query, body_hash)`, and
# `HTTP.download(host, query, path, cb)`, all returning the body
# string (or an exit status for `download`). Several Pokemon
# Essentials fangames call into `HTTP.*` directly for GameJolt
# trophies, version-check pings, and early-Uranium web probes.
#
# Our C++ already ships `HTTPLite.get/post/post_body` with a
# different signature: one URL, hash return `{status, body,
# headers}`. Rather than duplicate the binding, wrap it in Ruby.
#
# `HTTP.download` has no native analog - we could stream to disk
# via HTTPLite but the fangames that call it only need the
# progress callback fired and a non-error return. Return 200 and
# call the progress callback once at 100/100 so "check for update"
# probes see a benign success.
#
# All calls are wrapped in `begin...rescue` so a transient
# network failure surfaces to Ruby as an empty string rather
# than crashing the game. This matches JoiPlay's C++ behavior
# where any libcurl error path returns "" from the binding.

if defined?(HTTPLite)
  module HTTPLite
    class << self
      unless method_defined?(:__mkxp_native_get)
        alias __mkxp_native_get get
        alias __mkxp_native_post post
        alias __mkxp_native_post_body post_body

        def get(*args)
          __mkxp_native_get(*args)
        rescue Exception => e
          raise unless __mkxp_http_error?(e)
          __mkxp_empty_response('GET', args[0], e)
        end

        def post(*args)
          __mkxp_native_post(*args)
        rescue Exception => e
          raise unless __mkxp_http_error?(e)
          __mkxp_empty_response('POST', args[0], e)
        end

        def post_body(*args)
          __mkxp_native_post_body(*args)
        rescue Exception => e
          raise unless __mkxp_http_error?(e)
          __mkxp_empty_response('POST', args[0], e)
        end

        private

        def __mkxp_http_error?(error)
          error.is_a?(StandardError) || (defined?(MKXPError) && error.is_a?(MKXPError))
        end

        def __mkxp_empty_response(verb, url, error)
          if defined?(MKXP) && MKXP.respond_to?(:puts)
            MKXP.puts("[http] #{verb} #{url} failed: #{error.class}: #{error.message}")
          end
          { :status => 0, :body => '', :headers => {} }
        end
      end
    end
  end
end

module HTTP
  class << self
    def get(host, query = '')
      url = _join(host, query)
      result = HTTPLite.get(url)
      result.is_a?(Hash) ? (result[:body] || '') : result.to_s
    rescue StandardError => e
      _log_err('GET', url, e)
      ''
    end

    def post(host, query = '', body = {})
      url = _join(host, query)
      result = HTTPLite.post(url, body || {})
      result.is_a?(Hash) ? (result[:body] || '') : result.to_s
    rescue StandardError => e
      _log_err('POST', url, e)
      ''
    end

    # JoiPlay invokes this for trophy unlocks / update checks; a
    # success status is enough, our side does not need to stream
    # bytes to disk because those probes discard the payload.
    def download(host, query, _path, on_progress = nil)
      if on_progress.is_a?(String) && respond_to?(on_progress, true)
        send(on_progress, 100, 100)
      elsif on_progress.respond_to?(:call)
        on_progress.call(100, 100)
      end
      200
    rescue StandardError => e
      _log_err('DOWNLOAD', _join(host, query), e)
      0
    end

    private

    # Accept either a full URL in `host` with empty query, or a
    # host/scheme separate from a path/query. Avoid double slashes
    # or missing ones.
    def _join(host, query)
      host = host.to_s
      query = query.to_s
      return host if query.empty?
      return host + query if host.end_with?('/') || query.start_with?('/')
      return host + query if query.start_with?('?')

      "#{host}/#{query}"
    end

    def _log_err(verb, url, e)
      return unless defined?(MKXP) && MKXP.respond_to?(:puts)

      MKXP.puts("[http] #{verb} #{url} failed: #{e.class}: #{e.message}")
    end
  end
end
