# Pokemon fan-game online / network stubs.
#
# Pokemon Essentials fan games (Green Remix, Natural Green, Reborn,
# and others) ship online-oriented modules - GameJolt leaderboards,
# Downloader for runtime asset fetching, FontInstaller for shipping
# custom fonts, Berka network-error strings - that call native
# Windows libraries or require internet access that's either
# blocked on iOS or pointless for a sandboxed mobile port.
#
# Our platform_compat.rb IOS::NullStub const_missing hook only
# catches UNDEFINED constants. These modules get DEFINED by the
# game's own scripts, so the hook never fires for them - we have
# to override the definitions explicitly, after the game scripts
# have run, to replace their method bodies with safe no-ops.
#
# Behaviour matches JoiPlay's pokefix.rb so any fan game that
# works on JoiPlay should behave the same way here. Gated on the
# `PokemonSystem` *class* (not the `$PokemonSystem` instance,
# which is only initialized later when `pbStartLoadScreen` runs -
# the original gate was effectively always false at postload time
# and the stubs never applied even for the games they target).

# rubocop:disable Naming/AccessorMethodName, Naming/PredicateMethod, Naming/PredicatePrefix
# These modules mock external API surfaces (GameJolt, ADIK, Berka)
# that PE games call by exact method name. Renaming would break the
# game-side calls that this file exists to neutralise.
if defined?(PokemonSystem) && PokemonSystem.is_a?(Class)
  # When the host grants network access, the game's own online
  # modules (Downloader, GameJolt, URL probes) are left in place so
  # they can do their real work over the now-functional network
  # stack. The stubs below that *replace* game behavior only apply
  # in offline mode. Pure safety-net definitions (error-string
  # constants, FontInstaller, autosave) apply either way since they
  # neutralise Windows-only or undefined-constant crashes, not
  # networking.
  network_on = defined?(System) &&
               System.respond_to?(:network_enabled?) &&
               System.network_enabled?

  unless network_on
    # Runtime asset downloader used by Green Remix / Natural Green.
    # Replaced wholesale: report nothing-to-download, complete
    # immediately, and no-op every call site.
    module Downloader
      def self.downloading?
        false
      end

      def self.update; end

      def self.progress?
        100
      end

      def self.download(url, filename) end
      def self.createIfNecessary(f)    end
      def self.finishUp;               end
      def self.startNext;              end
    end
  end

  # Berka network-error string constants referenced by a handful of
  # fan games when raising exceptions. Define the namespace so any
  # `raise Berka::NetErrorErr, "msg"` resolves instead of hitting
  # const_missing (which would return IOS::NullStub, a non-Exception
  # subclass Ruby rejects as a raise target).
  module Berka
    module NetErrorErr
      ConIn    = 'Unable to connect to Internet'.freeze
      ConFtp   = 'Unable to connect to Ftp'.freeze
      ConHttp  = 'Unable to connect to the Server'.freeze
      NoFFtpIn = "The file to be downloaded doesn't exist".freeze
      NoFFtpEx = "The file to be uploaded doesn't exist".freeze
      TranHttp = 'Http Download failed'.freeze
      DownFtp  = 'Ftp Download failed'.freeze
      UpFtp    = 'Ftp Upload failed'.freeze
      NoFile   = 'No file to be downloaded'.freeze
      Mkdir    = 'Unable to create a new directory'.freeze
    end
  end

  # Natural Green probes external URLs via pbGetTextFromInternet.
  # Return empty string so downstream `.split` etc. get an empty
  # array instead of nil. Offline mode only - with network access
  # the game's own implementation is left to run.
  unless network_on
    def pbGetTextFromInternet(_url)
      ''
    end
  end

  # FontInstaller tries to shell out to the Windows font installer.
  # Silently succeed.
  module FontInstaller
    def self.install; end
  end

  # Top-level `autosave` no-op for PE19+ Autosave_Sapphire and
  # similar plugins. The plugin's `def autosave` lives at the top
  # level (`Kernel#autosave`). Without our stub the call site
  # raises `NoMethodError: undefined method 'autosave' for main`.
  # Define on Kernel so it's reachable from every receiver. Variadic
  # arity in case a plugin variant passes a save slot or filename.
  unless Kernel.method_defined?(:autosave) || Kernel.private_method_defined?(:autosave)
    module Kernel
      def autosave(*args); end
      module_function :autosave
    end
  end

  # GameJolt leaderboard / trophy API. Stub every documented entry
  # point. Return sensible neutral values (nil, false, empty string,
  # empty array) so games branching on "is the player logged in"
  # always take the offline path. Offline mode only.
  unless network_on
    module GameJolt
      @status = -1
      @error  = ''

      def self.login
        true
      end

      def self.login_status
        @status
      end

      def self.reset_status
        @status = -1
      end

      def self.is_logged_in
        false
      end

      def self.call
        login
      end

      def self.logoff
        @status = -1
        $user = nil
        $password = nil
      end

      def self.has_already_got_trophy?(_trophy_id)
        false
      end

      def self.award_trophy(trophy_id); end

      def self.submit_score(_score, *_args)
        false
      end

      def self.show_highscores(*args); end

      def self.do_request(_base_url)
        { 'success' => 'false' }
      end

      def self.make_bool(s)
        s == 'true'
      end

      def self.authenticate(_user, _token)
        true
      end

      def self.get_userdata_string; end

      def self.get_error
        @error
      end

      def self.sync_trophies; end

      def self.get_highscores_formatted(*_args)
        ''
      end

      def self.get_highscores(*_args)
        nil
      end

      def self.has_login_data
        defined?($userAgent) && $userAgent ? $userAgent.to_s : 'mkxp'
      end

      def self.enter_text(text = '', _var = nil, max_char = 30)
        $inputText = pbEnterText(text, 0, max_char, '', 3, nil) if defined?(pbEnterText)
      end
    end
  end

  # ADIK::DATA config struct referenced by some GameJolt-enabled
  # builds. Declaring it with safe defaults stops const_missing
  # from returning IOS::NullStub, which breaks `ADIK::DATA::FOLDER`
  # array iteration downstream.
  module ADIK
    module DATA
      DATA_PATH = 'CURRENT'.freeze
      FOLDER    = [].freeze
      FILENAME  = 'gjdata.data'.freeze
      AUTOSAVE  = false
    end
  end
end
# rubocop:enable Naming/AccessorMethodName, Naming/PredicateMethod, Naming/PredicatePrefix
