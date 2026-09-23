# Save folder paths for the Auto Multi Save plugin in the games by
# Rot8erConeX (Pokemon Entropy, Pokemon Entropic Eclipse, Pokemon
# Chaotic Crystal, and the rest of that family).
#
# The plugin's SaveData.get_engine_saves picks the save folder from
# System.data_directory: it splits the path on "\\", replaces the
# last name with the title of the game whose saves it wants, and
# joins the pieces with "\\" again. Each game in the family reads
# the saves of the others that way. The data directory here uses
# "/" as its separator, so the split yields one piece and the
# method returns a bare folder name. That name resolves next to the
# game files, no folder exists there, and every save fails with
# Errno::ENOENT.
#
# The plugin loads from PluginScripts.rxdata in Main, after this
# postload ran, so a plain alias cannot reach its method yet. A
# module prepended to the SaveData singleton class wins over the
# method the plugin defines later. The override puts the bare name
# back under the parent of the data directory, and creates the
# game's own folder there, since no other code makes it.
#
# On Windows the plugin has the same fault the other way: the data
# directory is named after the Game.ini title, "Pokemon Entropy",
# and nobody creates the sibling folder. Players fix that by hand.
# Here Empo names the data directory the same way, so the sibling
# folder is Data/<game title>/, next to the one Empo made.
module MkxpPokemonMultiSavePaths
  def get_engine_saves(region = nil)
    folder = super
    return folder if folder.include?('/')

    path = File.join(File.dirname(System.data_directory.chomp('/')), folder)
    Dir.mkdir(path) if region.nil? && !File.directory?(path)
    path
  end
end

if defined?(SaveData) && SaveData.respond_to?(:singleton_class) &&
   SaveData.singleton_class.respond_to?(:prepend)
  SaveData.singleton_class.prepend(MkxpPokemonMultiSavePaths)
end
