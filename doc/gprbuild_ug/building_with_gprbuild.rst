.. _Building_with_GPRbuild:

**********************
Building with GPRbuild
**********************

.. _Building_with_GPRbuild_Introduction:

Introduction
============


`GPRbuild` is a generic build tool designed for the construction of
large multi-language systems organized into subsystems and libraries.
It is well-suited for compiled languages supporting separate compilation,
such as Ada, C, C++ and Fortran.

`GPRbuild` manages a three step build process.

* compilation phase:

  Each compilation unit of each subsystem is examined in turn, checked for
  consistency, and compiled or recompiled when necessary by the appropriate
  compiler.  The recompilation decision is based on dependency information
  that is typically produced by a previous compilation.

* post-compilation phase (or binding):

  Compiled units from a given language are passed to a language-specific
  post-compilation tool if any. Also during this phase
  objects are grouped into static or dynamic libraries as specified.

* linking phase:

  All units or libraries from all subsystems are passed to a linker tool
  specific to the set of toolchains being used.


The tool is generic in that it provides, when possible, equivalent
build capabilities for all supported languages. For this, it uses a
configuration file :file:`<file>.cgpr` that has a syntax and structure very
similar to a project file, but which defines the characteristics
of the supported languages and toolchains. The configuration file contains
information such as:

* the default source naming conventions for each language,
* the compiler name, location and required options,
* how to compute inter-unit dependencies,
* how to build static or dynamic libraries,
* which post-compilation actions are needed,
* how to link together units from different languages.


On the other hand, `GPRbuild` is not a replacement for general-purpose
build tools such as `make` or `ant` which give the user a high
level of control over the build process itself. When building a system
requires complex actions that do not fit well in the three-phase process
described above, `GPRbuild` might not be sufficient.
In such situations, `GPRbuild` can still
be used to manage the appropriate part of the build. For
instance it can be called from within a Makefile.

.. _Command_Line:

Command Line
============

Three elements can optionally be specified on GPRbuild's command line:

* the main project file,
* the switches for GPRbuild itself or for the tools it
  drives, and
* the main source files.

The general syntax is thus:

::

   gprbuild [<proj>.gpr] [switches] [names]
    {[-cargs opts] [-cargs:lang opts] [-largs opts] [-kargs opts]
     [-gargs opts]}


GPRbuild requires a project file, which may be specified on the
command line either directly or through the :samp:`-P` switch. If not
specified, GPRbuild uses the project file :file:`default.gpr` if there
is one in the current working directory. Otherwise, if there is only
one project file in the current working directory, GPRbuild uses this
project file.

Main source files represent the sources to be used as the main
programs. If they are not specified on the command line, GPRbuild uses
the source files specified with the `Main` attribute in the project
file. If none exists, then no executable will be built.
It is also possible to specify absolute file names, or file names relative
to the current directory.

When source files are specified along with the option :samp:`-c`, then
recompilation will be considered only for those source files. In all
other cases, GPRbuild compiles or recompiles all sources in the
project tree that are not up to date, and builds or rebuilds libraries
that are not up to date.

If invoked without the :samp:`--config=` or
:samp:`--autoconf=` options, then GPRbuild will look for a configuration
project file. The file name or path name of this configuration project file
depends on the target, the runtime and environment variable `GPR_CONFIG`
See :ref:`Configuring_with_GPRconfig`. If there is no such file in the default
locations expected by GPRbuild (<install>/share/gpr and the current
directory) then GPRbuild will invoke GPRconfig with
the languages from the project files, and create a configuration project
file :file:`auto.cgpr` in the object directory of the main project. The project
:file:`auto.cgpr` will be rebuilt at each GPRbuild invocation unless you use
the switch :samp:`--autoconf=path/auto.cgpr`, which will use the configuration
project file if it exists and create it otherwise.

Options given on the GPRbuild command line may be passed along to
individual tools by preceding them with one of the "command line separators"
shown below. Options following the separator, up to the
next separator (or end of the command line), are passed along.  The
different command line separators are:

* :samp:`-cargs`

  The arguments that follow up to the next command line separator are
  options for all compilers for all languages.
  Example: :samp:`-cargs` :samp:`-g`

* :samp:`-cargs:{language name}`

  The arguments that follow up to the next command line separator are
  options for the compiler of the specific language.

  Examples:

  * :samp:`-cargs:Ada -gnatf`
  * :samp:`-cargs:C -E`

* :samp:`-bargs`

  The arguments that follow up to the next command line separator are
  options for all binder drivers.

* :samp:`-bargs:{language name}`

  The arguments that follow up to the next command line separators are
  options for the binder driver of the specific language.

  Examples:

  * :samp:`-bargs:Ada binder_prefix=ppc-elf`
  * :samp:`-bargs:C++ c_compiler_name=ccppc`

* :samp:`-largs`

  The arguments that follow up to the next command line separator are
  options for the linker, when linking an executable.

* :samp:`-kargs`

  The arguments that follow up to the next command line separator are
  options for gprconfig when performing auto-configuration.

* :samp:`-gargs`

  The arguments that follow up to the next command line separator are
  options for GPRbuild itself. Usually :samp:`-gargs` is specified after one or
  several other command line separators.

* :samp:`-margs`

  Equivalent to :samp:`-gargs`, provided for compatibility with
  *gnatmake*.

.. _Switches:

Switches
========

GPRbuild takes into account switches that may be specified on the command
line or in attributes Switches(<main or language>) or Default_Switches
(<language>) in package Builder of the main project.

When there are a single main (specified on the command line or in
attribute Main in the main project), the switches that are taken into account
in package Builder of the main project are Switches (<main>), if declared, or
Switches (<language of main>), if declared.

When there are several mains, if there are sources of the same language, then
Switches (<language of main>) is taken into account, if specified.

When there are no main specified, if there is only one compiled language
(that is a language with a non empty Compiler Driver), then
Switches (<single language>) is taken into account, if specified.

The switches that are interpreted directly by GPRbuild are listed below.

First, the switches that may be specified only on the command line, but not in
package Builder of the main project:

* :samp:`--build-script=<script_file>`

  This switch is not compatible with :samp:`--distributed=`.

  When this switch is specified, a shell script <script_file> is created.
  Provided that the temporary files created by gprbuild are not deleted,
  running this script should perform the same build as the invocation of
  gprbuild, with the same sources.

* :samp:`--no-project`

  This switch cannot be used if a project file is specified on the command
  line.

  When this switch is specified, it indicates to gprbuild that the project
  files in the current directory should not be considered and that the default
  project file in <prefix>/share/gpr is to be used.

  It is usually used with one or several mains specified on the command line.

* :samp:`--no-complete-output`

  Synonym: :samp:`-n`.

  By default, gprbuild redirects the standard output and the standard error of
  the compilations to different text files. This allows to inspect the results
  afterwards, and also ensures that parallel processes do not clobber each
  other's output. When this switch is specified, these files are not created
  and individual compilations output directly to common standard streams.

* :samp:`--complete-output`

  This switch is not compatible with :samp:`--distributed=`.

  When this switch is specified, if a source is up to date and compilation
  log files exist, their contents are sent to standard output
  and standard error. This allows to redisplay any warning or info from the
  last invocation of gprbuild.

* :samp:`--distributed[={slave1}[,{slave2}]]`

  This switch is not compatible with :samp:`--complete-output`, or with
  :samp:`--build-script=`.

  Activate the distributed compilation on the listed slaves nodes (IP or
  name). Or if no slave are specified they are search in `GPR_SLAVES` or
  `GPR_SLAVES_FILE` environment variables.
  see :ref:`Distributed_compilation`.

* :samp:`--hash={string}`

  Specify an hash string. This is just a value which is checked against the
  GPRslave hash value. If GPRslave has a hash value specified this string
  must match, otherwise it is ignored. For example:

::

  $ gprbuild --hash=$(echo $ADA_PROJECT_PATH | shasum) --distributed=...

* :samp:`--slave-env={name}`

  Use name as the slave's environment directory instead of the default one.
  This options is only used in distributed mode.

* :samp:`--version`

  Display information about GPRbuild: version, origin and legal status, then
  exit successfully, ignoring other options.

* :samp:`--help`

  Display GPRbuild usage, then exit successfully, ignoring other options.

* :samp:`--display-paths`

  Display two lines: the configuration project file search path and the user
  project file search path, then exit successfully, ignoring other options.

* :samp:`--config={config project file name}`

  This specifies the configuration project file name. By default, the
  configuration project file name is :file:`default.cgpr`. Option :samp:`--config=`
  cannot be specified more than once. The configuration project file specified
  with :samp:`--config=` must exist.

* :samp:`--autoconf={config project file name}`

  This specifies a configuration project file name that already exists
  or will be created automatically. Option :samp:`--autoconf=` cannot
  be specified more than once. If the configuration project file
  specified with :samp:`--autoconf=` exists, then it is
  used. Otherwise, GPRconfig is invoked to create it automatically.

* :samp:`--target={targetname}`

  This specifies that the default configuration project file is
  :file:`<targetname>.cgpr`. If no configuration project file with this name
  is found, then GPRconfig is invoked with option
  :samp:`--target={targetname}` to create a configuration project file
  :file:`auto.cgpr`.

  Note: only one of :samp:`--config`, :samp:`--autoconf` or :samp:`--target=`
  can be specified.

* :samp:`--implicit-with={project file name}`

  Adds a given project as an implicit dependency to every project in the
  build tree by creating an implicit "limited with" clause at the start of
  each project. This switch can only appear once on the command line.

* :samp:`--subdirs={subdir}`

  This indicates that the object, library and executable directories specified
  in the project file will be suffixed with {subdir}. If needed, those
  subdirectories are created except for externally built projects: in this case
  if the subdirectories already exist they are used, otherwise the base
  directories are used.

* :samp:`--src-subdirs={subdir}`

  This adds the given subdirectory (relative to each object directory of the
  project tree) to the list of source directories of the project, one directory
  per object directory. This is useful for overriding temporarily some source
  files for the purpose of e.g. source instrumentation such as source coverage
  or preprocessing. This option may be combined with :samp:`--subdirs`.

* :samp:`--relocate-build-tree[={dir}]`

  With this option it is possible to achieve out-of-tree build. That
  is, real object, library or exec directories are relocated to the
  current working directory or dir if specified.

* :samp:`--root-dir={dir}`

  This option is to be used with --relocate-build-tree above and
  cannot be specified alone. This option specifies the root directory
  for artifacts for proper relocation. The default value is the main
  project directory. This may not be suitable for relocation if for
  example some artifact directories are in parent directory of the
  main project. The specified directory must be a parent of all
  artifact directories.

* :samp:`--unchecked-shared-lib-imports`

  Allow shared library projects to import projects that are not shared
  library projects.

* :samp:`--source-info={source info file}`

  Specify a source info file. If the source info file is specified as a
  relative path, then it is relative to the object directory of the main
  project. If the source info file does not exist, then after the Project
  Manager has successfully parsed and processed the project files and found
  the sources, it creates the source info file. If the source info file
  already exists and can be read successfully, then the Project Manager will
  get all the needed information about the sources from the source info file
  and will not look for them. This reduces the time to process the project
  files, especially when looking for sources that take a long time. If the
  source info file exists but cannot be parsed successfully, the Project
  Manager will attempt to recreate it. If the Project Manager fails to create
  the source info file, a message is issued, but GPRbuild does not fail.

* :samp:`--restricted-to-languages={list of language names}`

  Restrict the sources to be compiled to one or several languages. Each
  language name in the list is separated from the next by a comma, without any
  space.

  Example: :samp:`--restricted-to-languages=Ada,C`

  When this switch is used, switches :samp:`-c`, :samp:`-b` and
  :samp:`-l` are ignored. Only the compilation phase is performed and the
  sources that are not in the list of restricted languages are not compiled,
  including mains specified in package Builder of the main project.

* :samp:`--no-sal-binding`

  Specify to GPRbuild to not rebind a Stand-Alone Library (SAL), but instead
  to reuse the files created during a previous build of the SAL. GPRbuild
  will fail if there are missing files. This option is unsafe and not
  recommended, as it may result in incorrect binding of the SAL, for example
  if sources have been added, removed or modified in a significant way related
  to binding. It is only provided to improve performance, when it is known
  that the resulting binding files will be the same as the previous ones.

* :samp:`-aP {dir}` (Add directory :file:`dir` to project search path)

  Specify to GPRbuild to add directory :file:`dir` to the user project file search
  path, before the default directory.

* :samp:`-d` (Display progress)

  Display progress for each source, up to date or not, as a single
  line *completed x out of y (zz%)...*. If the file needs to be compiled
  this is displayed after the invocation of the compiler. These lines are
  displayed even in quiet output mode (switch :samp:`-q`).

* :samp:`-I{nn}` (Index of main unit in multi-unit source file)
  Indicate the index of the main unit in a multi-unit source file.
  The index must be a positive number and there should be one and only
  one main source file name on the command line.

* :samp:`-eL` (Follow symbolic links when processing project files)

  By default, symbolic links on project files are not taken into account
  when processing project files. Switch :samp:`-eL` changes this default
  behavior.

* :samp:`-eS` (no effect)

  This switch is only accepted for compatibility with gnatmake, but it has
  no effect. For gnatmake, it means: echo commands to standard output instead
  of standard error, but for gprbuild, commands are always echoed to standard
  output.

* :samp:`-F` (Full project path name in brief error messages)

  By default, in non verbose mode, when an error occurs while processing
  a project file, only the simple name of the project file is displayed in the
  error message. When switch :samp:`-F` is used, the full path of the project
  file is used. This switch has no effect when switch :samp:`-v` is used.

* :samp:`-o {name}` (Choose an alternate executable name)

  Specify the file name of the executable. Switch :samp:`-o` can
  be used only if there is exactly one executable being built;
  that is, there is exactly one main on the command line,
  or there are no mains on the command line and exactly one
  main in attribute `Main` of the main project.

* :samp:`-P {proj}` (use Project file *proj*)

  Specify the path name of the main project file. The space between :samp:`-P`
  and the project file name is optional. Specifying a project file name (with
  suffix :file:`.gpr`) may be used in place of option :samp:`-P`. Exactly one main
  project file can be specified.

* :samp:`-r` (Recursive)

  This switch has an effect only when :samp:`-c` or :samp:`-u` is also
  specified and there are no mains: it means that all sources of all projects
  need to be compiled or recompiled.

* :samp:`-u` (Unique compilation, only compile the given files)

  If there are sources specified on the command line, only compile these
  sources. If there are no sources specified on the command line, compile
  all the sources of the main project.

  In both cases, do not attempt the binding and the linking phases.

* :samp:`-U` (Compile all sources of all projects)

  If there are sources specified on the command line, only compile these
  sources. If there are no sources specified on the command line, compile
  all the sources of all the projects in the project tree.

  In both cases, do not attempt the binding and the linking phases.

* :samp:`-vP{x}` (Specify verbosity when parsing Project Files)

  By default, GPRbuild does not display anything when processing project files,
  except when there are errors. This default behavior is obtained with switch
  :samp:`-vP0`. Switches :samp:`-vP1` and :samp:`-vP2` yield increasingly
  detailed output.

* :samp:`-Xnm={val}` (Specify an external reference for Project Files)

  Specify an external reference that may be queried inside the project files
  using built-in function `external`. For example, with
  :samp:`-XBUILD=DEBUG`,
  `external("BUILD")` inside a project file will have the value
  `"DEBUG"`.

* :samp:`--compiler-subst={lang},{tool}` (Specify alternative compiler)

  Use *tool* for compiling files in language *lang*,
  instead of the normal compiler. For example, if
  :samp:`--compiler-subst=ada,my-compiler` is given, then Ada files
  will be compiled with *my-compiler* instead of the usual
  *gcc*. This and :samp:`--compiler-pkg-subst` are intended
  primarily for use by ASIS tools using :samp:`--incremental` mode.

* :samp:`--compiler-pkg-subst={pkg}` (Specify alternative package)

  Use the switches in project-file package *pkg* when running
  the compiler, instead of the ones in package Compiler.


Then, the switches that may be specified on the command line as well as in
package Builder of the main project (attribute Switches):

* :samp:`--keep-temp-files`

  Normally, GPRbuild delete the temporary files that it creates.
  When this switch is used, the temporary files that GPRbuild creates are
  not deleted.

* :samp:`--create-map-file`

  When linking an executable, if supported by the platform, create a map file
  with the same name as the executable, but with suffix :file:`.map`.

* :samp:`--create-map-file={map file}`

  When linking an executable, if supported by the platform, create a map file
  with file name :file:`map file`.

* :samp:`--autodetect-jobserver`

  Specify to GPRbuild that it should attempt to connect to GNU make jobserver
  in order to be instructed when it is allowed to spawn another simultaneous
  compilation jobs.
  This option should be used when GNU make contains :samp:`-j{num}` switch when
  invoking GPRbuild to ensure correct ressources allocation.
  
  If :samp:`-j{num}` is set alongside :samp:`--autodetect-jobserver`
  the former will be ignored.

* :samp:`--no-indirect-imports`

  This indicates that sources of a project should import only sources or
  header files from directly imported projects, that is those projects mentioned
  in a with clause and the projects they extend directly or indirectly.
  A check is done in the compilation phase, after a successful compilation, that
  the sources follow these restrictions. For Ada sources, the check is fully
  enforced. For non Ada sources, the check is partial, as in the dependency
  file there is no distinction between header files directly included and those
  indirectly included. The check will fail if there is no possibility that a
  header file in a non directly imported project could have been indirectly
  imported. If the check fails, the compilation artifacts (dependency file,
  object file, switches file) are deleted.

* :samp:`--indirect-imports`

  This indicates that sources of a project can import sources or header files
  from directly or indirectly imported projects. This is the default behavior.
  This switch is provided to cancel a previous switch
  :samp:`--no-indirect-imports` on the command line.

* :samp:`--no-object-check`

  Do not check if an object has been created after compilation.

* :samp:`--no-split-units`

  Forbid the sources of the same Ada unit to be in different projects.

* :samp:`--single-compile-per-obj-dir`

  Disallow several simultaneous compilations for the same object directory.

* :samp:`-b` (Bind only)

  Specify to GPRbuild that the post-compilation (or binding) phase is to be
  performed, but not the other phases unless they are specified by appropriate
  switches.

* :samp:`-c` (Compile only)

  Specify to GPRbuild that the compilation phase is to be performed, but not
  the other phases unless they are specified by appropriate switches.

* :samp:`-f` (Force recompilations)

  Force the complete processing of all phases (or of those explicitly specified)
  even when up to date.

* :samp:`-j{num}` (use *num* simultaneous compilation jobs)

  By default, GPRbuild invokes one compiler at a time. With switch :samp:`-j`,
  it is possible to instruct GPRbuild to spawn several simultaneous compilation
  jobs if needed. For example, :samp:`-j2` for two simultaneous compilation
  jobs or :samp:`-j4` for four. On a multi-processor system,
  :samp:`-j{num}` can greatly speed up the build process. If :samp:`-j0` is
  used, then the maximum number of simultaneous compilation jobs is the number
  of core processors on the platform.

  Switch :samp:`-j{num}` is also used to spawned several simultaneous binding
  processes and several simultaneous linking processes when there are several
  mains to be bound and/or linked.

  Note: if :samp:`--autodetect-jobserver` is set, then :samp:`-j{num}` will
  simply be ignored.

* :samp:`-k` (Keep going after compilation errors)

  By default, GPRbuild stops spawning new compilation jobs at the first
  compilation failure. Using switch :samp:`-k`, it is possible to attempt to
  compile/recompile all the sources that are not up to date, even when some
  compilations failed. The post-compilation phase and the linking phase are never
  attempted if there are compilation failures, even when switch :samp:`-k` is
  used.

* :samp:`-l` (Link only)

  Specify to GPRbuild that the linking phase is to be performed, but not
  the other phases unless they are specified by appropriate switches.

* :samp:`-m` (Minimum Ada recompilation)

  Do not recompile Ada code if timestamps are different but checksums are the
  same. Note that for the case when source code contains preprocessing
  directives, this switch has no effect.

* :samp:`-m2` (Checksum based recompilation)

  Recompile Ada code even if timestamps are the same, but checksums are
  different. Note that for the case when source code contains preprocessing
  directives, this switch has the same effect as -f.

* :samp:`-p` or :samp:`--create-missing-dirs` (Create missing object, library and exec directories)

  By default, GPRbuild checks that the object, library and exec directories
  specified in project files exist. GPRbuild automatically creates any of these
  directories which is specified relatively to the project dir, for instance
  :samp:`for Object_Dir use "obj/"`. The :samp:`-p` switch instructs GPRbuild
  to attempt to create missing directories that are specified as absolute paths
  as well. Note that these switches may be specified in package Builder of the
  main project, but they are not useful there as either the directories already
  exist or the processing of the project files has failed before the evaluation
  of the Builder switches, because there is at least one missing directory.

* :samp:`-q` (Quiet output)

  Do not display anything except errors and progress (switch :samp:`-d`).
  Cancel any previous switch :samp:`-v`.

* :samp:`-R` (no run path option)

  Do not use a run path option to link executables or shared libraries,
  even when attribute Run_Path_Option is specified.

* :samp:`-s` (recompile if compilation switches have changed)

  By default, GPRbuild will not recompile a source if all dependencies are
  satisfied. Switch :samp:`-s` instructs GPRbuild to recompile sources when a
  different set of compilation switches has been used in the previous
  compilation, even if all dependencies are satisfied. Each time GPRbuild
  invokes a compiler, it writes a text file that lists the switches used in the
  invocation of the compiler, so that it can retrieve these switches if
  :samp:`-s` is used later.

* :samp:`-v` (Verbose output)

  Same as switch :samp:`-vl`.

* :samp:`-vl` (Verbose output, low level)

  Display full paths, all options used in spawned processes, as well as
  creations of missing directories and changes of current working directories.

* :samp:`-vm` (Verbose output, medium level)

  Not significantly different from switch :samp:`-vh`.

* :samp:`-vh` (Verbose output, high level)

  In addition to what is displayed with switch :samp:`vl`, displayed internal
  behavior of gprbuild and reasons why the spawned processes are invoked.

* :samp:`-we` (Treat all warnings as errors)

  When :samp:`-we` is used, any warning during the processing of the project
  files becomes an error and GPRbuild does not attempt any of the phases.

* :samp:`-wn` (Treat warnings as warnings)

  Switch :samp:`-wn` may be used to restore the default after :samp:`-we` or
  :samp:`-ws`.

* :samp:`-ws` (Suppress all warnings)

  Do not generate any warnings while processing the project files.
  Note that this switch is only for warnings generated by gprbuild,
  not for warnings generated by the compiler.
  Use the compiler switch :samp:`-gnatws` to suppress warnings generated by
  the GNAT front end, and the compiler switch :samp:`-w` to suppress warnings
  generated by the gcc back end.

* :samp:`-x` (Create include path file)

  Create the include path file for the Ada compiler.
  This switch is often necessary when Ada sources are compiled with switch
  :samp:`-gnatep=`.

Switches that are accepted for compatibility with gnatmake, either on the
command line or in the Builder Ada switches in the main project file:

* :samp:`-nostdinc`
* :samp:`-nostdlib`
* :samp:`-fstack-check`
* :samp:`-fno-inline`
* :samp:`-g{*}` Any switch starting with :samp:`-g`
* :samp:`-O{*}` Any switch starting with :samp:`-O`


These switches are passed to the Ada compiler.

.. _Initialization:

Initialization
==============

Before performing one or several of its three phases, GPRbuild has to read the
command line, obtain its configuration, and process the project files.

If GPRbuild is invoked with an invalid switch or without any project file on
the command line, it will fail immediately.

Examples:


::

  $ gprbuild -P
  gprbuild: project file name missing after -P

  $ gprbuild -P c_main.gpr -WW
  gprbuild: illegal option "-WW"


GPRbuild looks for the configuration project file first in the current
working directory, then in the default configuration project directory.
If the GPRbuild executable is located in a subdirectory :file:`<prefix>/bin`,
then
the default configuration project directory is :file:`<prefix>/share/gpr`,
otherwise there is no default configuration project directory.

When it has found its configuration project path, GPRbuild needs to obtain its
configuration. By default, the file name of the main configuration project
is :file:`default.cgpr`. This default may be modified using the switch
:samp:`--config=...`

Example:


::

  $ gprbuild --config=my_standard.cgpr -P my_project.gpr


If GPRbuild cannot find the main configuration project on the configuration
project path, then it will look for all the languages specified in the user
project tree and invoke GPRconfig to create a temporary configuration project
file. This file is located in the directory computed by the following sequence:
* Look for a valid absolute path in the environment variables TMPDIR, TEMP, and
TMP.
* If this fails, check some predefined platform-specific temp dirs (e.g. /tmp
for linux).
* Finally if none is accessible we fall back onto the current working
directory.

The invocation of GPRconfig will take into account the target, if specified
either by switch --target= on the command line or by attribute Target in the
main project. Also, if Ada is one of the languages, it will take into account
the Ada runtime directory, specified either by switches --RTS= or --RTS:ada= on
the command line or by attribute Runtime ("Ada") in the main project file. If
the Ada runtime is specified as a relative path, gprbuild will try to locate
the Ada runtime directory as a subdirectory of the main project directory, or
if environment variable GPR_RUNTIME_PATH is defined in the path specified
by GPR_RUNTIME_PATH.

Once it has found the configuration project, GPRbuild will process its
configuration: if a single string attribute is specified in the configuration
project and is not specified in a user project, then the attribute is added
to the user project. If a string list attribute is specified in the
configuration project then its value is prepended to the corresponding
attribute in the user project.

After GPRbuild has processed its configuration, it will
process the user project file or files. If these user project files are
incorrect then GPRbuild will fail with the appropriate error messages:


::

  $ gprbuild -P my_project.gpr
  ada_main.gpr:3:26: "src" is not a valid directory
  gprbuild: "my_project.gpr" processing failed


Once the user project files have been dealt with successfully, GPRbuild
will start its processing.

.. _Compilation_of_one_or_several_sources:

Compilation of one or several sources
=====================================

If GPRbuild is invoked with :samp:`-u` or :samp:`-U` and there are one or
several source file names specified on the command line, GPRbuild will compile
or recompile these sources, if they are not up to date or if :samp:`-f` is
also specified. Then GPRbuild will stop its execution.

The options/switches used to compile these sources are described in section
:ref:`Compilation_Phase`.

If GPRbuild is invoked with :samp:`-u` and no source file name is specified
on the command line, GPRbuild will compile or recompile all the sources of the
*main* project and then stop.

In contrast, if GPRbuild is invoked with :samp:`-U`, and again no source file name is specified
on the command line, GPRbuild will compile or recompile all the sources of
*all the projects in the project tree* and then stop.

.. _Compilation_Phase:

Compilation Phase
=================

When switch :samp:`-c` is used or when switches :samp:`-b` or :samp:`-l`
are not used, GPRbuild will first compile or recompile the sources that
are not up to date in all the projects in the project tree. The sources
considered are:

* all the sources in languages other than Ada

* if there are no main specified, all the Ada sources

* if there is a non Ada main, but no attribute `Roots` specified for
  this main, all the Ada sources

* if there is a main with an attribute `Roots` specified, all
  the Ada sources in the closures of these Roots.

* if there is an Ada main specified, all the Ada sources in the closure
  of the main


Attribute Roots takes as an index a main and a string list value. Each string
in the list is the name of an Ada library unit.

Example:

::

     for Roots ("main.c") use ("pkga", "pkgb");

Package PkgA and PkgB will be considered, and all the Ada units in their
closure will also be considered.

GPRbuild will first consider each source and decide if it needs to be
(re)compiled.

A source needs to be compiled in the following cases:

* Switch :samp:`-f` (force recompilations) is used

* The object file does not exist

* The source is more recent than the object file

* The dependency file does not exist

* The source is more recent than the dependency file

* When :samp:`-s` is used: the switch file does not exist

* When :samp:`-s` is used: the source is more recent than the switch file

* The dependency file cannot be read

* The dependency file is empty

* The dependency file has a wrong format

* A source listed in the dependency file does not exist

* A source listed in the dependency file has an incompatible time stamp

* A source listed in the dependency file has been replaced

* Switch :samp:`-s` is used and the source has been compiled with
  different switches or with the same switches in a different order


When a source is successfully compiled, the following files are normally
created in the object directory of the project of the source:

* An object file

* A dependency file, except when the dependency kind for the language
  is `none`

* A switch file if switch :samp:`-s` is used


The compiler for the language corresponding to the source file name is invoked with the following
switches/options:

* The required compilation switches for the language

* The compilation switches coming from package `Compiler` of the
  project of the source

* The compilation switches specified on the command line for all compilers,
  after :samp:`-cargs`

* The compilation switches for the language of the source, specified
  after :samp:`-cargs:{language}`

* Various other options including a switch to create the dependency file
  while compiling, a switch to specify a configuration file, a switch
  to specify a mapping file, and switches to indicate where to look for
  other source or header files that are needed to compile the source.


If compilation is needed, then all the options/switches, except those
described as 'Various other options' are written to the switch file.
The switch file is a text file. Its file name is obtained by replacing
the suffix of the source with :file:`.cswi`. For example, the switch file
for source :file:`main.adb` is :file:`main.cswi` and for
:file:`toto.c` it is :file:`toto.cswi`.

If the compilation is successful, then if the creation of the dependency
file is not done during compilation but after (see configuration attribute
`Compute_Dependency`), then the process to create the dependency file is
invoked.

For each project file, attribute Interfaces may be declared. Its value is a
list of sources or header files of the project file. For a project file
extending another one, directly or indirectly, inherited sources may be in
the list. When Interfaces is not declared, all sources or header files are
part of the interface of the project. When Interfaces is declared, only those
sources or header files are part of the interface of the project file. After
a successful compilation, gprbuild checks that all imported or included sources
or header files that are from an imported project are part of the interface of
the imported project. If this check fails, the compilation is invalidated and
the compilation artifacts (dependency, object and switches files) are deleted.

Example:

::

     project Prj is
        for Languages use ("Ada", "C");
        for Interfaces use ("pkg.ads", "toto.h");
     end Prj;

If a source from a project importing project Prj imports sources from Prj other
than package Pkg or includes header files from Prj other than "toto.h", then
its compilation will be invalidated.

.. _Simultaneous_compilation:

Simultaneous compilation
========================

If GPRbuild is invoked with a switch :samp:`-j` specifying more than one
compilation process, then several compilation processes for several sources of
possibly different languages are spawned concurrently.

Furthermore, GPRbuild is GNU make jobserver compatible when using the switch
:samp:`--autodetect-jobserver`. This means if GPRbuild is embedded in a GNU make 
recursive invocation and :samp:`--autodetect-jobserver` is set, then GPRbuild
will only spawn an additionnal compilation process if GNU make's jobserver
allows it. This is particularly useful to ensure that GPRbuild comply to the
ressource management of GNU make.

Example:

::

     build1:
       +gprbuild -P prjA/prj.gpr --autodetect-jobserver

     build2:
       +gprbuild -P prjB/prj.gpr --autodetect-jobserver

     build_all:
       +make build1 build2

calling :samp:`make build_all -j4` will spawn two GPRbuild processes, resulting in
two remaining and available slots for both GPRbuild compilation phase.

Note: If :samp:`--autodetect-jobserver` is set, then any :samp:`-j{num}` will simply
be ignored by GPRbuild and a warning will be issued.

.. _Post-Compilation_Phase:

Post-Compilation Phase
======================

The post-compilation phase has two parts: library building and program binding.

If there are libraries that need to be built or rebuilt, *gprbuild* will
call the library builder, specified by attribute `Library_Builder`.
This is generally the tool *gprlib*, provided with GPRbuild. If gprbuild
can determine that a library is already up to date, then the library builder
will not be called.

If there are mains specified, and for these mains there are sources of
languages with a binder driver (specified by attribute Binder'Driver
(<language>), then the binder driver is called for each such main, but only
if it needs to.

For Ada, the binder driver is normally *gprbind*, which will call
the appropriate version of *gnatbind*, that either the one in the same
directory as the Ada compiler or the fist one found on the path.
When neither of those is appropriate, it is possible to specify to
*gprbind* the full path of *gnatbind*, using the Binder switch
`--gnatbind_path=`.

Example:

::

     package Binder is
        for Switches ("Ada") use ("--gnatbind_path=/toto/gnatbind");
     end Binder;

If GPRbuild can determine that the artifacts from a previous
post-compilation phase are already up to date, the binder driver is not called.

If there are no libraries and no binder drivers, then the post-compilation
phase is empty.


.. _Linking_Phase:

Linking Phase
=============

When there are mains specified, either in attribute Main or on the command
line, and these mains are not up to date, the linker is invoked for each main,
with all the specified or implied options, including the object files generated
during the post-compilation phase by the binder drivers.

If switch :samp:`-j{nnn}` is used, with `nnn` other than 1, gprbuild will attempt to link
simultaneously up to `nnn` executables.


.. _Distributed_compilation:

Distributed compilation
=======================

.. _Introduction_to_distributed_compilation:

Introduction to distributed compilation
---------------------------------------

For large projects the compilation time can become a limitation in
the development cycle. To cope with that, GPRbuild supports
distributed compilation.

In the distributed mode, the local machine (called the build master)
compiles locally but also sends compilation requests to remote
machines (called the build slaves). The compilation process can use
one or more build slaves. Once the compilation phase is done, the
build master will conduct the binding and linking phases locally.

.. _Setup_build_environments:

Setup build environments
------------------------

The configuration process to be able to use the distributed compilation
support is the following:

* Optionally add a Remote package in the main project file

  This Remote package is to be placed into the project file that is passed
  to GPRbuild to build the application.

  The Root_Dir default value is the project's directory. This attribute
  designates the sources root directory. That is, the directory from which
  all the sources are to be found to build the application. If the project
  passed to GPRbuild to build the application is not at the top-level
  directory but in a direct sub-directory the Remote package should be:

  .. code-block:: gpr

      package Remote is
         for Root_Dir use "..";
      end Remote;

* Launch a slave driver on each build slave

  The build master will communicate with each build slave with a specific driver
  in charge of running the compilation process and returning statuses. This
  driver is *gprslave*, :ref:`GPRslave`.

  The requirement for the slaves are:

  * The same build environment must be setup (same compiler version).
  * The same libraries must be installed. That is, if the GNAT
    project makes use of external libraries the corresponding C headers or
    Ada units must be installed on the remote slaves.

  When all the requirement are set, just launch the slave driver:

  ::

      $ gprslave

When all this is done, the remote compilation can be used simply by
running GPRbuild in distributed mode from the build master:

::

    $ gprbuild --distributed=comp1.xyz.com,comp2.xyz.com prj.gpr

Alternatively the slaves can be set using the `GPR_SLAVES` environment
variable. So the following command is equivalent to the above:

::

    $ export GPR_SLAVES=comp1.xyz.com,comp2.xyz.com
    $ gprbuild --distributed prj.gpr

A third alternative is proposed using a list of slaves in a file (one
per line). In this case the `GPR_SLAVES_FILE` environment variable
must contain the path name to this file:

::

    $ export GPR_SLAVES_FILE=$HOME/slave-list.txt
    $ gprbuild --distributed prj.gpr

Finally note that the search for the slaves are in this specific
order. First the command line values, then `GPR_SLAVES` if set and
finally `GPR_SLAVES_FILES`.

The build slaves are specified with the following form:

::

    <machine_name>[:port]


.. _GPRslave:

GPRslave
--------

This is the slave driver in charge of running the compilation
jobs as requested by the build master. One instance of this tool must be
launched in each build slave referenced in the project file.

Compilations for a specific project are conducted under a sub-directory
from where the slave is launched by default. This can be overridden
with the `-d` option below.

The current options are:

* :samp:`-v, --verbose`

  Activate the verbose mode

* :samp:`-vv`, :samp:`--debug`

  Activate the debug mode (very verbose)

* :samp:`-h`, :samp:`--help`

  Display the usage

* :samp:`-d`, :samp:`--directory=`

  Set the work directory for the
  slave. This is where the sources will be copied and where the
  compilation will take place. A sub-directory will be created for each
  root project built.

* :samp:`-s`, :samp:`--hash={string}`

  Specify an hash string. This is just a value which is checked against the
  GPRbuild hash value. If set, GPRbuild hash value must match, otherwise the
  connection with the slave is aborted. For example:

::

  $ gprslave --hash=$(echo $ADA_PROJECT_PATH | shasum)

* :samp:`-j{N}`, :samp:`--jobs={N}`

  Set the maximum simultaneous compilation.
  The default for `N` is the number of cores.

* :samp:`-p`, :samp:`--port={N}`

  Set the port the slave will listen to.
  The default value is 8484. The same port must be specified for the
  build slaves on `GPRbuild` command line.

* :samp:`-r`, :samp:`--response-handler={N}`

  Set maximum number of simultaneous responses.
  With this option it is possible to control the number of simultaneous
  responses (sending back object code and ALI files) supported. The
  value must be between 1 and the maximum number of simultaneous
  compilations.

Note that a slave can be pinged to see if it is running and in
response a set of information are delivered. The ping command has the
following format:

::

   <lower-bound><upper-bound>PG

When <lower-bound> and <upper-bound> are 32bits binary values for the
PG string command. As an example here is how to send a ping command
from a UNIX shell using the echo command:

::

   echo -e "\x01\x00\x00\x00\x02\x00\x00\x00PG" | nc <HOSTNAME> 8484

The answer from the ping command has the following format:

::
   OK<GPR Version String>[ASCII.GS]<time-stamp>[ASCII.GS]<slave hash>

The ASCII.GS is the Group Separator character whose code is 29.
