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
# `HTTP.download` streams for real through `HTTPLite.download`. With
# network access toggled off the native client refuses and the
# download reports 0, the same failed status airplane mode produces
# on JoiPlay. Builds without the native download (desktop) keep the
# historical fake-success fallback.
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
        alias __mkxp_native_download download if method_defined?(:download)

        # rubocop:disable Lint/RescueException -- JoiPlay returns "" on any binding error, not just StandardError
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

        if method_defined?(:__mkxp_native_download)
          def download(*args)
            __mkxp_native_download(*args)
          rescue Exception => e
            raise unless __mkxp_http_error?(e)

            __mkxp_empty_response('DOWNLOAD', args[0], e)
          end
        end
        # rubocop:enable Lint/RescueException

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

    def download(host, query, path, on_progress = nil)
      url = _join(host, query)
      # No native download (desktop build): keep the historical fake.
      # With networking toggled off the native client refuses and the
      # rescue below reports 0 - the same failed download airplane
      # mode produces on JoiPlay.
      return _fake_download(on_progress) unless HTTPLite.respond_to?(:download)

      # The native callback contract is a top-level method name;
      # Procs/Methods can't cross into C, so run those transfers
      # callback-less and fire the callable once at completion.
      native_cb = on_progress.is_a?(String) || on_progress.is_a?(Symbol) ? on_progress : nil
      result = HTTPLite.download(url, path, native_cb)
      status = result.is_a?(Hash) ? (result[:status] || 0) : 0
      on_progress.call(100, 100) if native_cb.nil? && on_progress.respond_to?(:call) && status == 200
      status
    rescue StandardError => e
      _log_err('DOWNLOAD', _join(host, query), e)
      0
    end

    private

    # Offline fake: benign success, no bytes transferred.
    def _fake_download(on_progress)
      if on_progress.is_a?(String) && respond_to?(on_progress, true)
        send(on_progress, 100, 100)
      elsif on_progress.respond_to?(:call)
        on_progress.call(100, 100)
      end
      200
    end

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
