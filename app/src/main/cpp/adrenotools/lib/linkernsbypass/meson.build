linkernsbypass_files = files(['android_linker_ns.cpp', 'android_linker_ns.h', 'elf_soname_patcher.cpp', 'elf_soname_patcher.h'])
linkernsbypass_inc = include_directories('.')

libdl_dep = cpp.find_library('dl')

linkernsbypass_lib = static_library (
    'linkernsbypass',
    linkernsbypass_files,
    c_args: (['-Wall', '-Wextra']),
    cpp_args: (['-Wall', '-Wextra']),
    include_directories: ([linkernsbypass_inc, adrenotools_inc]),
    dependencies: ([libandroid_dep, libdl_dep])
)

# linkernsbypass_include = static_library('linkernsbypass', sources)
# target_compile_options(['linkernsbypass', 'PRIVATE', '-Wall', '-Wextra'])
# target_link_libraries(['linkernsbypass', 'android', 'dl'])
# target_include_directories(['linkernsbypass', 'PUBLIC', '.'])
