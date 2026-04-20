
if get_option('mri_includes') == ''
    ver = get_option('mri_version')
    if ver.version_compare('>=3.0') and compilers['cpp'].get_id() == 'clang'
        global_args += '-fdeclspec'
    endif
    global_dependencies += dependency('ruby-' + ver)
    global_args += '-DMKXPZ_RUBY_VERSION="@0@"'.format(ver)
else
    global_args += ('-I' + get_option('mri_includes'))
    global_dependencies += compilers['cpp'].find_library(get_option('mri_library'), dirs: get_option('mri_libpath'))
    # MKXPZ_RUBY_VERSION can be set via -Dmri_version when using custom
    # includes/libpath; if unset, the bridge reports "unknown".
    if get_option('mri_version') != ''
        global_args += '-DMKXPZ_RUBY_VERSION="@0@"'.format(get_option('mri_version'))
    endif
endif

global_include_dirs += include_directories('.')

binding_source = [files(
    'binding-mri.cpp',
    'binding-util.cpp',
    'table-binding.cpp',
    'etc-binding.cpp',
    'bitmap-binding.cpp',
    'font-binding.cpp',
    'graphics-binding.cpp',
    'input-binding.cpp',
    'sprite-binding.cpp',
    'viewport-binding.cpp',
    'plane-binding.cpp',
    'window-binding.cpp',
    'tilemap-binding.cpp',
    'audio-binding.cpp',
    'module_rpg.cpp',
    'filesystem-binding.cpp',
    'windowvx-binding.cpp',
    'tilemapvx-binding.cpp',
    'http-binding.cpp'
)]

if steamworks == true
    binding_source += files('cusl-binding.cpp')
endif

if miniffi == true
    binding_source += files('miniffi-binding.cpp')
    binding_source += files('miniffi.cpp')
endif

global_sources += binding_source
