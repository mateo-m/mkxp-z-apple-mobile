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
# works on JoiPlay should behave the same way here. Gated on
# $PokemonSystem so this only runs for Pokemon Essentials games.

if !$PokemonSystem.nil?
  # Runtime asset downloader used by Green Remix / Natural Green.
  # Replaced wholesale: report nothing-to-download, complete
  # immediately, and no-op every call site.
  module Downloader
    def self.downloading?;           false end
    def self.update;                 end
    def self.progress?;              100   end
    def self.download(url, filename) end
    def self.createIfNecessary(f)    end
    def self.finishUp;               end
    def self.startNext;              end
  end

  # Berka network-error string constants referenced by a handful of
  # fan games when raising exceptions. Define the namespace so any
  # `raise Berka::NetErrorErr, "msg"` resolves instead of hitting
  # const_missing (which would return IOS::NullStub, a non-Exception
  # subclass Ruby rejects as a raise target).
  module Berka
    module NetErrorErr
      ConIn    = "Unable to connect to Internet"
      ConFtp   = "Unable to connect to Ftp"
      ConHttp  = "Unable to connect to the Server"
      NoFFtpIn = "The file to be downloaded doesn't exist"
      NoFFtpEx = "The file to be uploaded doesn't exist"
      TranHttp = "Http Download failed"
      DownFtp  = "Ftp Download failed"
      UpFtp    = "Ftp Upload failed"
      NoFile   = "No file to be downloaded"
      Mkdir    = "Unable to create a new directory"
    end
  end

  # Natural Green probes external URLs via pbGetTextFromInternet;
  # return empty string so downstream `.split` etc. get an empty
  # array instead of nil.
  def pbGetTextFromInternet(url)
    ""
  end

  # FontInstaller tries to shell out to the Windows font installer.
  # Silently succeed.
  module FontInstaller
    def self.install; end
  end

  # Top-level `autosave` no-op for PE19+ Autosave_Sapphire and
  # similar plugins. The plugin's `def autosave` lives at the top
  # level (`Kernel#autosave`); without our stub the call site
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
  # point; return sensible neutral values (nil, false, empty string,
  # empty array) so games branching on "is the player logged in"
  # always take the offline path.
  module GameJolt
    @status = -1
    @error  = ""

    def self.login;          true end
    def self.login_status;   @status end
    def self.reset_status;   @status = -1 end
    def self.is_logged_in;   false end
    def self.call;           self.login end
    def self.logoff
      @status = -1
      $user = nil
      $password = nil
    end

    def self.has_already_got_trophy?(trophy_id); false end
    def self.award_trophy(trophy_id);            end
    def self.submit_score(score, *args);         false end
    def self.show_highscores(*args);             end

    def self.do_request(base_url);               {"success" => "false"} end
    def self.make_bool(s);                       s == "true" end
    def self.authenticate(user, token);          true end
    def self.get_userdata_string;                end
    def self.get_error;                          @error end
    def self.sync_trophies;                      end
    def self.get_highscores_formatted(*args);    "" end
    def self.get_highscores(*args);              nil end
    def self.has_login_data;                     "Empo" end

    def self.enter_text(text = "", var = nil, max_char = 30)
      $inputText = pbEnterText(text, 0, max_char, "", 3, nil) if defined?(pbEnterText)
    end
  end

  # ADIK::DATA config struct referenced by some GameJolt-enabled
  # builds. Declaring it with safe defaults stops const_missing
  # from returning IOS::NullStub, which breaks `ADIK::DATA::FOLDER`
  # array iteration downstream.
  module ADIK
    module DATA
      DATA_PATH = "CURRENT"
      FOLDER    = []
      FILENAME  = "gjdata.data"
      AUTOSAVE  = false
    end
  end
end
