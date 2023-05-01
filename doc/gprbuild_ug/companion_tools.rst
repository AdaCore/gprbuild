.. _GPRbuild_Companion_Tools:

************************
GPRbuild Companion Tools
************************

This chapter describes the various tools that can be used in conjunction with GPRbuild.

.. _Configuring_with_GPRconfig:

Configuring with GPRconfig
==========================

.. _Configuration:

Configuration
-------------

GPRbuild requires one configuration file describing the languages and
toolchains to be used, and project files describing the
characteristics of the user project. Typically the configuration
file can be created automatically by `GPRbuild` based on the languages
defined in your projects and the compilers on your path. In more
involved situations --- such as cross compilation, or
environments with several compilers for the same language ---
you may need to control more precisely the generation of
the desired configuration of toolsets. A tool, GPRconfig, described in
:ref:`Configuring_with_GPRconfig`), offers this capability. In this
chapter most of the examples can use autoconfiguration.

GPRbuild will start its build process by trying to locate a configuration
file, using the following rules.

* If either `--config` or `--autoconf` switches are specified, the argument
  of this switch is used as configuration file.

* If neither switch is specified, and both target and rts are explicitly
  specified in the project or on the command line, then configuration file
  is called `<target>-<rts>.cgpr`; if only target or only rts is specified, it
  is called `<target.cgpr` or `<rts>.cgpr` respectively; if neither
  is specified, it is called `default.cgpr`. This file is looked for in the
  current directory.

* If the environment variable `GPR_CONFIG` is specified, the above rule is
  modified as follows: if this variable designates a directory, then this
  directory is searched for the configuration file instead of the current
  directory; otherwise, the value of this variable is used as a configuration
  file name (absolute or relative).

GPRbuild assumes that there are known compilers on your path for each of
the necessary languages. A user can manually generate a
configuration file (and reference it using `--config` switch); this is
especially useful when:

  * using cross compilers (in which case you need to use gprconfig's
    :samp:`--target=`) option;
  * using a specific Ada runtime (e.g. :samp:`--RTS=sjlj`);
  * working with compilers not in the path or not first in the path;
  * autoconfiguration does not give the expected results;
  * autoconfiguration perceptively delays the build.

GPRconfig provides several ways of generating configuration files. By
default, a simple interactive mode lists all the known compilers for all
known languages. You can then select a compiler for each of the languages;
once a compiler has been selected, only compatible compilers for other
languages are proposed. Here are a few examples of GPRconfig
invocation:

* The following command triggers interactive mode. The configuration will be
  generated in GPRbuild's default location, `./default.cgpr)`, unless
  :samp:`-o` is used.

  ::

      gprconfig

* The first command below also triggers interactive mode, but the resulting
  configuration
  file has the name and path selected by the user. The second command shows
  how GPRbuild can make use of this specific configuration file instead of
  the default one.

  ::

      gprconfig -o path/my_config.cgpr
      gprbuild --config=path/my_config.cgpr

* The following command again triggers interactive mode, and only the
  relevant cross compilers for target ppc-elf will be proposed.

  ::

      gprconfig --target=ppc-elf

* The next command triggers batch mode and generates at the default location
  a configuration file using the first native Ada and C compilers on
  the path.

  ::

      gprconfig --config=Ada --config=C --batch

* The next command, a combination of the previous examples, creates in
  batch mode a configuration file named :file:`x.cgpr` for cross-compiling
  Ada with a run-time called `hi` and using C for the LEON
  processor.

  ::

      gprconfig --target=leon-elf --config=Ada,,hi --config=C --batch -o x.cgpr


.. _Using_GPRconfig:

Using GPRconfig
---------------

Description
^^^^^^^^^^^

The GPRconfig tool helps you generate the configuration
files for GPRbuild. It automatically detects the available compilers
on your system and, after you have selected the one needed for your
application, it generates the proper configuration file.

.. note::

  In general, you will not launch GPRconfig
  explicitly. Instead, it is used implicitly by GPRbuild through the use
  of `--config` and `--autoconf` switches.

Command line arguments
^^^^^^^^^^^^^^^^^^^^^^

GPRconfig supports the following command line switches:

.. index:: --target (gprconfig)

:samp:`--target={platform}`

  ..  -- @TIPHTML{Use :samp:`--target` to specify on which machine your application will run}

  This switch indicates the target computer on which your application will
  be run. It is mostly useful for cross configurations. Examples include
  :samp:`ppc-elf`, :samp:`ppc-vx6-windows`. It can also be used in native
  configurations and is useful when the same machine can run different kind
  of compilers such as mingw32 and cygwin on Windows or x86-32 and x86-64
  on GNU Linux. Since different compilers will often return a different
  name for those targets, GPRconfig has an extensive knowledge of which
  targets are compatible, and will for example accept :samp:`x86-linux` as
  an alias for :samp:`i686-pc-linux-gnu`.
  The default target is the machine on which GPRconfig is run.

  If you enter the special target :samp:`all`, then all compilers found on the
  :envvar:`PATH` will be displayed.

.. index:: --show-target (gprconfig)

:samp:`--show-targets`

  As mentioned above, GPRconfig knows which targets are compatible. You
  can use this switch to find the list of targets that are compatible
  with `--target`.

.. index:: --config (gprconfig)

:samp:`--config={language}[,{version}[,{runtime}[,{path}[,{name}]]]]`

  .. -- @TIPHTML{Use :samp:`--config` to automatically select the first matching compiler}

  The intent of this switch is to preselect one or more compilers directly
  from the command line. This switch takes several optional arguments, which
  you can omit simply by passing the empty string. When omitted, the arguments
  will be computed automatically by GPRconfig.

  In general, only *language* needs to be specified, and the first
  compiler on the :envvar:`PATH` that can compile this language will be selected.
  As an example, for a multi-language application programmed in C and Ada,
  the command line would be:

  ::

      --config=Ada --config=C

  *path* is the directory that contains the compiler executable, for
  instance :file:`/usr/bin` (and not the installation prefix :file:`/usr`).

  *name* should be one of the compiler names defined in the GPRconfig
  knowledge base. The list of supported names includes :samp:`GNAT`,
  :samp:`GCC`,.... This name is
  generally not needed, but can be used to distinguish among several compilers
  that could match the other arguments of :samp:`--config`.

  Another possible more frequent use of *name* is to specify the base
  name of an executable. For instance, if you prefer to use a diab C compiler
  (executable is called :file:`dcc`) instead of :file:`gcc`, even if the latter
  appears first in the path, you could specify :file:`dcc` as the name parameter.

  ::

      gprconfig --config Ada,,,/usr/bin       # automatic parameters
      gprconfig --config C,,,/usr/bin,GCC     # automatic version
      gprconfig --config C,,,/usr/bin,gcc     # same as above, with exec name

  This switch is also the only possibility to include in your project some
  languages that are not associated with a compiler. This is sometimes useful
  especially when you are using environments like GPS that support project files.
  For instance, if you select "Project file" as a language, the files matching
  the :file:`.gpr` extension will be shown in the editor, although they of course
  play no role for gprbuild itself.

.. index:: --batch (gprconfig)

:samp:`--batch`

  .. -- @TIPHTML{Use :samp:`--batch` to generate the configuration file with no user interaction}

  If this switch is specified, GPRconfig automatically selects the first
  compiler matching each of the `--config` switches, and generates the
  configuration file immediately. It will not display an interactive menu.

.. index:: -o (gprconfig)

:samp:`-o {file}`

  .. -- @TIPHTML{Use :samp:`-o` to specify the name of the configuration file to generate}

  This specifies the name of the configuration file that will be generated.
  If this switch is not specified, a default file is generated in the
  installation directory of GPRbuild (assuming you have write access to
  that directory), so that it is automatically picked up by GPRbuild later
  on. If you select a different output file, you will need to specify it
  to GPRbuild.

.. index:: --db (gprconfig)

:samp:`--db {directory}`, :samp:`--db-`
  Indicates another directory that should be parsed for GPRconfig's knowledge
  base. Most of the time this is only useful if you are creating your own
  XML description files locally. Additional directories are always processed
  after the default knowledge base. The second version of the switch prevents
  GPRconfig from reading its default knowledge base.

.. index:: -h (gprconfig)

:samp:`-h`
  Generates a brief help message listing all GPRconfig switches and the
  default value for their arguments. This includes the location of the
  knowledge base, the default target, etc.


Interactive use
^^^^^^^^^^^^^^^

When you launch GPRconfig, it first searches for all compilers it
can find on your :envvar:`PATH`, that match the target specified by
:samp:`--target`. It is recommended, although not
required, that you place the compilers that you expect to use for your
application in your :envvar:`PATH` before you launch *gprconfig*,
since that simplifies the setup.

.. -- @TIPHTML{The list of compilers is sorted so that the most likely compilers appear first}

GPRconfig then displays the list of all the compilers
it has found, along with the language they can compile, the run-time
they use (when applicable),.... It then waits for you to select
one of the compilers.  This list is sorted by language, then by order
in the :envvar:`PATH` environment variable (so that compilers that you
are more likely to use appear first), then by run-time names and
finally by version of the compiler.  Thus the first
compiler for any language is most likely the one you want to use.

You make a selection by entering the letter that appears on the line for
each compiler (be aware that this letter is case sensitive). If the compiler was
already selected, it is deselected.

.. -- @TIPHTML{The list of compilers is filtered, so that only compatible compilers can be selected}

A filtered list of compilers is then displayed:
only compilers that target the same platform as the selected
compiler are now shown. GPRconfig then checks whether it is
possible to link sources compiled with the selected compiler and each of
the remaining compilers; when linking is not possible, the compiler is not
displayed. Likewise, all compilers for the same language are hidden, so that
you can only select one compiler per language.

As an example, if you need to compile your application with several C compilers,
you should create another language, for instance called C2, for that purpose.
That will give you the flexibility to indicate in the project files which
compiler should be used for which sources.

The goal of this filtering is to make it more obvious whether you have
a good chance of being able to link. There is however no guarantee that
GPRconfig will know for certain how to link any combination of the
remaining compilers.

You can select as many compilers as are needed by your application. Once you
have finished selecting the compilers, select :kbd:`s`, and GPRconfig will
generate the configuration file.


.. _The_GPRconfig_knowledge_base:

The GPRconfig knowledge base
----------------------------

GPRconfig itself has no hard-coded knowledge of compilers. Thus there
is no need to recompile a new version of GPRconfig when a new compiler
is distributed.

.. note::

   The role and format of the knowledge base are irrelevant for most users
   of GPRconfig, and are only needed when you need to add support for new
   compilers. You can skip this section if you only want to learn how to use
   GPRconfig.

All knowledge of compilers is embedded in a set of XML files called the
*knowledge base*.
Users can easily contribute to this general knowledge base, and have
GPRconfig immediately take advantage of any new data.

The knowledge base contains various kinds of information:

* Compiler description

  When it is run interactively, GPRconfig searches the user's
  :envvar:`PATH` for known compilers, and tries to deduce their
  configuration (version, supported languages, supported targets, run-times,
  ...). From the knowledge base GPRconfig knows how to extract the
  relevant information about a compiler.

  This step is optional, since a user can also enter all the information
  manually. However, it is recommended that the knowledge base explicitly
  list its known compilers, to make configuration easier for end users.

* Specific compilation switches

  When a compiler is used, depending on its version, target, run-time,...,
  some specific command line switches might have to be supplied. The
  knowledge base is a good place to store such information.

  For instance, with the GNAT compiler, using the soft-float runtime should
  force *gprbuild* to use the :samp:`-msoft-float` compilation switch.

* Linker options

  Linking a multi-language application often has some subtleties,
  and typically requires specific linker switches.
  These switches depend on the list of languages, the list
  of compilers,....

* Unsupported compiler mix

  It is sometimes not possible to link together code compiled with two
  particular compilers. The knowledge base should store this information,
  so that end users are informed immediately when attempting to
  use such a compiler combination.

The end of this section will describe in more detail the format of this
knowledge base, so that you can add your own information
and have GPRconfig advantage of it.


.. _General_file_format:

General file format
^^^^^^^^^^^^^^^^^^^

The knowledge base is implemented as a set of XML files. None of these
files has a special name, nor a special role. Instead, the user can
freely create new files, and put them in the knowledge base directory,
to contribute new knowledge.

The location of the knowledge base is :file:`$prefix/share/gprconfig`,
where :file:`$prefix` is the directory in which GPRconfig was
installed. Any file with extension :file:`.xml` in this directory will
be parsed automatically by GPRconfig at startup after sorting
them alphabetically.

All files must have the following format:

::

    <?xml version="1.0" ?>
    <gprconfig>
       ...
    </gprconfig>

The root tag must be `<gprconfig>`.

The remaining sections in this chapter will list the valid XML tags that
can be used to replace the '...' code above. These tags can either all be
placed in a single XML file, or split across several files.


.. _Compiler_description:

Compiler description
^^^^^^^^^^^^^^^^^^^^

One of the XML tags that can be specified as a child of `<gprconfig>` is
`<compiler_description>`. This node and its children describe one of
the compilers known to GPRconfig. The tool uses them when it
initially looks for all compilers known on the user's :envvar:`PATH`
environment variable.

This is optional information, but simplifies the use of GPRconfig,
since the user is then able to omit some parameters from the :samp:`--config`
command line argument, and have them automatically computed.

The `<compiler_description>` node doesn't accept any XML
attribute.  However, it accepts a number of child tags that explain
how to query the various attributes of the compiler.  The child tags
are evaluated (if necessary) in the same order as they are documented below.


*<name>*
  This tag contains a simple string, which is the name of the compiler.
  This name must be unique across all the configuration files, and is used to
  identify that `compiler_description` node.

  ::

       <compiler_description>
       <name>GNAT</name>
       </compiler_description>

*<executable>*
  This tag contains a string, which is the name of an executable
  to search for on the PATH. Examples are :samp:`gnatls`, :samp:`gcc`,...

  In some cases, the tools have a common suffix, but a prefix that might depend
  on the target. For instance, GNAT uses :samp:`gnatmake` for native platforms,
  but :samp:`powerpc-wrs-vxworks-gnatmake` for cross-compilers to VxWorks.
  Most of the compiler description is the same, however.
  For such cases, the value of the `executable` node is considered as
  beginning a regular expression. The tag also accepts an optional
  attribute `prefix`,
  which is an integer indicating the parenthesis group that contains the prefix.
  In the following example, you obtain the version of the GNAT compiler by running
  either *gnatls* or *powerpc-wrs-vxworks-gnatls*, depending on
  the name of the executable that was found.

  The regular expression needs to match the whole name of the file, i.e. it
  contains an implicit '^' at the start, and an implicit '$' at the end.
  Therefore if you specify :samp:`.*gnatmake` as the regexp, it will not match
  :samp:`gnatmake-debug`.

  A special case is when this node is empty (but it must be specified!). In
  such a case, you must also specify the language (see <language> below) as a
  simple string. It is then assumed that the specified language does not
  require a compiler. In the configurations file (:ref:`Configurations`),
  you can test whether that language was specified on the command line by
  using a filter such as

  ::

      <compilers>
       <compiler language="name"/>
      </compilers>


  ::

      <executable prefix="1">(powerpc-wrs-vxworks-)?gnatmake</executable>
      <version><external>${PREFIX}gnatls -v</external></version>

  GPRconfig searches in all directories listed on the PATH for such
  an executable. When one is found, the rest of the `<compiler_description>`
  children are checked to know whether the compiler is valid. The directory
  in which the executable was found becomes the 'current directory' for
  the remaining XML children.

*<target>*
  This node indicates how to query the target architecture for the compiler.
  See :ref:`GPRconfig_external_values` for valid children.

  If this isn't specified, the compiler will always be considered as matching
  on the current target.

*<version>*
  This tag contains any of the nodes defined in :ref:`GPRconfig_external_values` below.
  It shows how to query the version number of the compiler. If the version
  cannot be found, the executable will not be listed in the list of compilers.


*<variable name="varname">*
  This node will define a user variable which may be later referenced.  The
  variables are evaluated just after the version but before the languages
  and the runtimes nodes.  See :ref:`GPRconfig_external_values`
  below for valid children of
  this node.  If the evaluation of this variable is empty then the compiler
  is considered as invalid.

*<languages>*
  This node indicates how to query the list of languages. See
  :ref:`GPRconfig_external_values`
  below for valid children of this node.

  The value returned by the system will be split into words. As a result, if
  the returned value is 'ada,c,c++', there are three languages supported by the
  compiler (and three entries are added to the menu when using GPRconfig
  interactively).

  If the value is a simple string, the words must be comma-separated, so that
  you can specify languages whose names include spaces. However, if the actual
  value is computed from the result of a command, the words can also be
  space-separated, to be compatible with more tools.

*<runtimes>*
  This node indicates how to query the list of supported runtimes for the
  compiler. See :ref:`GPRconfig_external_values`
  below for valid children. The returned value
  is split into words as for `<languages>`.

  This node accepts one attribute, `"default"`, which contains a list
  of comma-separated names of runtimes. It is used to sort the runtimes when
  listing which compilers were found on the PATH.

  As a special case, gprconfig will merge two runtimes if the XML nodes
  refer to the same directories after normalization and resolution of
  links. As such, on Unix systems, the "adalib" link to "rts-native/adalib"
  (or similar) will be ignored and only the "native" runtime will be
  displayed.


.. _GPRconfig_external_values:

GPRconfig external values
^^^^^^^^^^^^^^^^^^^^^^^^^

A number of the XML nodes described above can contain one or more children,
and specify how to query a value from an executable. Here is the list of
valid contents for these nodes. The `<directory>` and `<external>`
children can be repeated multiple times, and the `<filter>` and
`<must_match>` nodes will be applied to each of these. The final
value of the external value is the concatenation of the computation for each
of the `<directory>` and `<external>` nodes.

.. index:: gprconfig external values

* A simple string

  A simple string given in the node indicates a constant. For
  instance, the list of supported languages might be defined as:

  ::

      <compiler_description>
      <name>GNAT</name>
      <executable>gnatmake</executable>
      <languages>Ada</languages>
      </compiler_description>

  for the GNAT compiler, since this is an Ada-only compiler.

  Variables can be referenced in simple strings.

* `<getenv name="variable" />`

  If the contents of the node is a `<getenv>` child, the value of
  the environment variable `variable` is returned. If the variable is
  not defined, this is an error and the compiler is ignored.

  ::

      <compiler_description>
      <name>GCC-WRS</name>
      <executable prefix="1">cc(arm|pentium)</executable>
      <version>
      <getenv name="WIND_BASE" />
      </version>
      </compile_description>

* `<external>command</external>`

  If the contents of the node is an `<external>` child, this indicates
  that a command should be run on the system.
  When the command is run, the current directory (i.e., the one that contains
  the executable found through the `<executable>` node), is placed first
  on the :envvar:`PATH`. The output of the command is returned and may be later
  filtered. The command is not executed through a shell; therefore you cannot
  use output redirection, pipes, or other advanced features.

  For instance, extracting the target processor from *gcc* can be done
  with:

  ::

      <version>
      <external>gcc -dumpmachine</external>
      </version>

  Since the :envvar:`PATH` has been modified, we know that the *gcc* command
  that is executed is the one from the same directory as the `<external>`
  node.

  Variables are substituted in `command`.

* `<grep regexp="regexp" group="0" />`

  This node must come after the previously described ones. It is used to
  further filter the output. The previous output is matched against the regular
  expression `regexp` and the parenthesis group specified by
  `group` is returned. By default, group is 0, which indicates the
  whole output of the command.

  For instance, extracting the version number from *gcc* can be done
  with:

  ::

      <version>
      <external>gcc -v</external>
      <grep regexp="^gcc version (\S+)" group="1" />
      </version>

* `<directory group="0" contents="">regexp</directory>`

  If the contents of the node is a `<directory`> child, this
  indicates that GPRconfig should find all the files matching the
  regular expression. Regexp is a path relative to the directory that contains
  the `<executable>` file, and should use Unix directory separators
  (i.e. '/'), since the actual directory will be converted into this format
  before the match, for system independence of the knowledge base.

  The group attribute indicates which parenthesis group should be returned.
  It defaults to 0 which indicates the whole matched path. If this attribute is
  a string rather than an integer, then it is the value returned.

  `regexp` can be any valid regular expression. This will only match
  a directory or file name, not a subdirectory. Remember to quote special
  characters, including '.', if you do not mean to use a regexp.

  The optional attribute `contents` can be used to indicate that the
  contents of the file should be read. The first line that matches the regular
  expression given by `contents` will be used as a file path instead of
  the file matched by `regexp`. This is in general used on platforms that
  do not have symbolic links, and a file is used instead of a symbolic link.
  In general, this will work better than `group` specifies a string rather
  than a parenthesis group, since the latter will match the path matched by
  `regexp`, not the one read in the file.

  For instance, finding the list of supported runtimes for the GNAT compiler
  is done with:

  ::

      <runtimes>
      <directory group="1">
      \.\./lib/gcc/${TARGET/.*/rts-(.*)/adainclude
      </directory>
      <directory group="default">
      \.\./lib/gcc/${TARGET}/.*/adainclude
      </directory>
      </runtimes>}

  Note the second node, which matches the default run-time, and displays it as
  such.

* `<filter>value1,value2,...</filter>`

  This node must come after one of the previously described ones. It is used to
  further filter the output. The previous output is split into words (it is
  considered as a comma-separated or space-separated list of words), and only
  those words in :samp:`value1`, :samp:`value2`,... are kept.

  For instance, the *gcc* compiler will return a variety of supported
  languages, including 'ada'. If we do not want to use it as an Ada
  compiler we can specify:

  ::

      <languages>
      <external regexp="languages=(\S+)" group="1">gcc -v</external>
      <filter>c,c++,fortran</filter>
      </languages>

* `<must_match>regexp</must_match>`

  If this node is present, then the filtered output is compared with the
  specified regular expression. If no match is found, then the executable
  is not stored in the list of known compilers.

  For instance, if you want to have a `<compiler_description>` tag
  specific to an older version of GCC, you could write:

  ::

      <version>
      <external regexp="gcc version (\S+)"
      group="1">gcc -v </external>
      <must_match>2.8.1</must_match>
      </version>

  Other versions of gcc will not match this `<compiler_description>`
  node.

.. _GPRconfig_variable_substitution:

GPRconfig variable substitution
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

The various compiler attributes defined above are made available as
variables in the rest of the XML files. Each of these variables can be used
in the value of the various nodes (for instance in `<directory>`),
and in the configurations (:ref:`Configuration`).

A variable is referenced by `${name}` where `name` is either
a user variable or a predefined variable.  An alternate reference is
`$name` where `name` is a sequence of alpha numeric characters or
underscores.  Finally `$$` is replaced by a simple `$`.

User variables are defined by `<variable>` nodes and may override
predefined variables.  To avoid a possible override use lower case names.

The variables are used in two contexts: either in a
`<compiler_description>` node, in which case the variable refers to
the compiler we are describing, or within a `<configuration>` node.
In the latter case, and since there might be several compilers selected,
you need to further specify the variable by adding in parenthesis the
language of the compiler you are interested in.

For instance, the following is invalid:

::

    <configuration>
    <compilers>
    <compiler name="GNAT" />
    </compilers>
    <targets negate="true">
    <target name="^powerpc-elf$"/>
    </targets>
    <config>
    package Compiler is
      for Driver ("Ada") use "${PATH}gcc";   --  Invalid !
    end Compiler;
    </config>
    </configuration>

The trouble with the above is that if you are using multiple languages
like C and Ada, both compilers will match the "negate" part, and therefore
there is an ambiguity for the value of `${PATH}`. To prevent such
issues, you need to use the following syntax instead when inside a
`<configuration>` node:

.. code-block:: gpr

    for Driver ("Ada") use "${PATH(ada)}gcc";   --  Correct

Predefined variables are always in upper case.  Here is the list of
predefined variables

* *EXEC*
    is the name of the executable that was found through `<executable>`. It
    only contains the basename, not the directory information.


* *HOST*
    is replaced by the architecture of the host on which GPRconfig is
    running. This name is hard-coded in GPRconfig itself, and is generated
    by *configure* when GPRconfig was built.


* *TARGET*
    is replaced by the target architecture of the compiler, as returned by the
    `<target>` node. This is of course not available when computing the
    target itself.

    This variable takes the language of the compiler as an optional index when
    in a `<configuration>` block: if the language is specified, the target
    returned by that specific compiler is used; otherwise, the normalized target
    common to all the selected compilers will be returned (target normalization
    is also described in the knowledge base's XML files).


* *VERSION*
    is replaced by the version of the compiler. This is not available when
    computing the target or, of course, the version itself.


* *PREFIX*
    is replaced by the prefix to the executable name, as defined by the
    `<executable>` node.


* *PATH*
    is the current directory, i.e. the one containing the executable found through
    `<executable>`. It always ends with a directory separator.


* *LANGUAGE*
    is the language supported by the compiler, always folded to lower-case


* *RUNTIME*, *RUNTIME_DIR*
    This string will always be substituted by the empty string when the
    value of the external value is computed. These are special strings
    used when substituting text in configuration chunks.

    `RUNTIME_DIR` always end with a directory separator.


* *GPRCONFIG_PREFIX*
    is the directory in which GPRconfig was installed (e.g
    :file:`"/usr/local/"` if the executable is :file:`"/usr/local/bin/gprconfig"`.
    This directory always ends with a directory separator.
    This variable never takes a language in parameter, even within a
    `<configuration>` node.


If a variable is not defined, an error message is issued and the variable
is substituted by an empty string.


.. _Configurations:

Configurations
^^^^^^^^^^^^^^

The second type of information stored in the knowledge base are the chunks
of *gprbuild* configuration files.

Each of these chunks is also placed in an XML node that provides optional
filters. If all the filters match, then the chunk will be merged with other
similar chunks and placed in the final configuration file that is generated
by GPRconfig.

For instance, it is possible to indicate that a chunk should only be
included if the GNAT compiler with the soft-float runtime is used. Such
a chunk can for instance be used to ensure that Ada sources are always
compiled with the `-msoft-float` command line switch.

GPRconfig does not perform sophisticated merging of chunks. It simply
groups packages together. For example, if the two chunks are:

.. code-block:: gpr

   chunk1:
      package Language_Processing is
        for Attr1 use ("foo");
      end Language_Processing;
   chunk2:
      package Language_Processing is
        for Attr1 use ("bar");
      end Language_Processing;

Then the final configuration file will look like:

.. code-block:: gpr

    package Language_Processing is
      for Attr1 use ("foo");
      for Attr1 use ("bar");
    end Language_Processing;

As a result, to avoid conflicts, it is recommended that the chunks be
written so that they easily collaborate together. For instance,
to obtain something equivalent to

.. code-block:: gpr

   package Language_Processing is
     for Attr1 use ("foo", "bar");
   end Language_Processing;

the two chunks above should be written as:

.. code-block:: gpr

    chunk1:
      package Language_Processing is
        for Attr1 use Language_Processing'Attr1 & ("foo");
      end Language_Processing;
    chunk2:
      package Language_Processing is
        for Attr1 use Language_Processing'Attr1 & ("bar");
    end Language_Processing;

The chunks are described in a `<configuration>` XML node. The most
important child of such a node is `<config>`, which contains the
chunk itself. For instance, you would write:

::

   <configuration>
     ...  list of filters, see below
     <config>
     package Language_Processing is
        for Attr1 use Language_Processing'Attr1 & ("foo");
     end Language_Processing;
     </config>
   </configuration>

If `<config>` is an empty node (i.e., :samp:`<config/>` or
:samp:`<config></config>` was used), then the combination of selected
compilers will be reported as invalid, in the sense that code
compiled with these compilers cannot be linked together. As a result,
GPRconfig will not create the configuration file.

The special variables (:ref:`GPRconfig_variable_substitution`) are also
substituted in the chunk. That allows you to compute some attributes of the
compiler (its path, the runtime,...), and use them when generating the
chunks.

The filters themselves are of course defined through XML tags, and can
be any of:

*<compilers negate="false">*
  This filter contains a list of `<compiler>` children. The
  `<compilers>` filter matches if any of its children match.
  However, you can have several `<compilers>` filters, in which
  case they must all match. This can be used to include linker switches
  chunks. For instance, the following code would be used to describe
  the linker switches to use when GNAT 5.05 or 5.04 is used in addition to
  g++ 3.4.1:

  ::

     <configuration>
       <compilers>
         <compiler name="GNAT" version="5.04" />
         <compiler name="GNAT" version="5.05" />
       </compilers>
       <compilers>
         <compiler name="G++" version="3.4.1" />
       </compilers>
       ...
     </configuration>

  If the attribute `negate` is :samp:`true`, then the meaning of this
  filter is inverted, and it will match if none of its children matches.

  The format of the `<compiler>` is the following:

  ::

     <compiler name="name" version="..."
     runtime="..." language="..." />

  The language attribute, when specified, matches
  the corresponding attribute used in the `<compiler_description>`
  children. All other attributes are regular expressions, which are matched
  against the corresponding selected compilers. Runtime attribute is matched
  against the base name of corresponding compiler runtime if it is given
  as a full path. When an attribute is not specified, it will always match.
  Matching is done in a case-insensitive manner.

  For instance, to check a GNAT compiler in the 5.x family, use:

  ::

     <compiler name="GNAT" version="5.\d+" />

*<hosts negate="false">*
  This filter contains a list of `<host>` children. It matches when
  any of its children matches. You can specify only one `<hosts>`
  node.
  The format of `<host>` is a node with one mandatory attribute
  `name`, which is a regexp matched against the architecture on
  which GPRconfig is running, and one optional attribute `except`, which
  is also a regexp, but a negative one. If both `name` and `except` match
  the architecture, corresponding `<configuration>` node is ignored.
  The name of the architecture was
  computed by `configure` when GPRconfig was built. Note that
  the regexp might match a substring of the host name, so you might want
  to surround it with "^" and "$" so that it only matches the whole host
  name (for instance, "elf" would match "powerpc-elf", but "^elf$" would
  not).

  If the `negate` attribute is :samp:`true`, then the meaning of this
  filter is inverted, and it will match when none of its children matches.

  For instance, to activate a chunk only if the compiler is running on an
  Intel Linux machine, use:

  ::

     <hosts>
       <host name="i.86-.*-linux(-gnu)?" />
     </hosts>

*<targets negate="false">*
  This filter contains a list of `<target>` children. It behaves
  exactly like `<hosts>`, but matches against the architecture
  targeted by the selected compilers. For instance, to activate a chunk
  only when the code is targeted for linux, use:

  If the `negate` attribute is :samp:`true`, then the meaning of this filter
  is inverted, and it will match when none of its children matches.

  ::

     <targets>
       <target name="i.86-.*-linux(-gnu)?" />
     </targets>

.. _Configuration_File_Reference:

Configuration File Reference
============================

A text file using the project file syntax. It defines languages and
their characteristics as well as toolchains for those languages and their
characteristics.

GPRbuild needs to have a configuration file to know the different
characteristics of the toolchains that can be used to compile sources and
build libraries and executables.

A configuration file is a special kind of project file: it uses the same
syntax as a standard project file. Attributes in the configuration file
define the configuration. Some of these attributes have a special meaning
in the configuration.

The default name of the configuration file, when not specified to
GPRbuild by switches :samp:`--config=` or :samp:`--autoconf=` is
:file:`default.cgpr`. Although the name of the configuration file can
be any valid file name, it is recommended that its suffix be
:file:`.cgpr` (for Configuration GNAT Project), so that it cannot be
confused with a standard project file which has the suffix
:file:`.gpr`.

When :file:`default.cgpr` cannot be found in the configuration project path,
GPRbuild invokes GPRconfig to create a configuration file.

In the following description of the attributes, when an attribute is an
indexed attribute and its index is a language name, for example
`Spec_Suffix (<language>)`, then the name of the language is case insensitive.
For example, both `C` and `c` are allowed.

Any attribute may appear in a configuration project file. All attributes in
a configuration project file are inherited by each user project file in the
project tree. However, usually only the attributes listed below make sense
in the configuration project file.


.. _Project_Level_Configuration_Attributes:

Project Level Configuration Attributes
--------------------------------------


.. _General_Attributes:

General Attributes
^^^^^^^^^^^^^^^^^^


* Default_Language

  Specifies the name of the language of the immediate sources of a project when
  attribute `Languages` is not declared in the project. If attribute
  `Default_Language` is not declared in the configuration file, then each user
  project file in the project tree must have an attribute `Languages` declared,
  unless it extends another project. Example:

  .. code-block:: gpr

       for Default_Language use "ada";

* Run_Path_Option

  Specifies a 'run path option'; i.e., an option to use when linking an
  executable or a shared library to indicate the path (Rpath) where to look
  for other libraries. The value of this attribute is a string list.
  When linking an executable or a shared library, the search path is
  concatenated with the last string in the list, which may be an empty string.

  Example:

  .. code-block:: gpr

        for Run_Path_Option  use ("-Wl,-rpath,");

* Run_Path_Origin

  Specifies the string to be used in an Rpath to indicate the directory
  of the executable, allowing then to have Rpaths specified as relative paths.

  Example:

  .. code-block:: gpr

        for Run_Path_Origin use "$ORIGIN";

* Toolchain_Version (<language>)

  Specifies a version for a toolchain, as a single string. This toolchain
  version is passed to the library builder. Example:

  .. code-block:: gpr

        for Toolchain_Version ("Ada") use "GNAT 6.1";

  This attribute is used by GPRbind to decide on the names of the shared GNAT
  runtime libraries.

* Toolchain_Description (<language>)

  Specifies as a single string a description of a toolchain. This attribute is
  not directly used by GPRbuild or its auxiliary tools (GPRbind and GPRlib) but
  may be used by other tools, for example GPS. Example:

  .. code-block:: gpr

        for Toolchain_Description ("C") use "gcc version 4.1.3 20070425";


.. _General_Library_Related_Attributes:

General Library Related Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* Library_Support

  Specifies the level of support for library project. If this attribute is not
  specified, then library projects are not supported. The only potential values
  for this attribute are `none`, `static_only` and `full`. Example:

  .. code-block:: gpr

       for Library_Support use "full";

* Library_Builder

  Specifies the name of the executable for the library builder. Example:

  .. code-block:: gpr

       for Library_Builder use "/.../gprlib";


.. _Archive_Related_Attributes:

Archive Related Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^

* Archive_Builder

  Specifies the name of the executable of the archive builder with the minimum
  options, if any. Example:

  .. code-block:: gpr

       for Archive_Builder use ("ar", "cr");

* Archive_Indexer

  Specifies the name of the executable of the archive indexer with the minimum
  options, if any. If this attribute is not specified, then there is no
  archive indexer. Example:

  .. code-block:: gpr

        for Archive_Indexer use ("ranlib");

* Archive_Suffix

  Specifies the suffix of the archives. If this attribute is not specified, then
  the suffix of the archives is defaulted to :file:`.a`. Example:

  .. code-block:: gpr

       for Archive_Suffix use ".olb"; --  for VMS

* Library_Partial_Linker

  Specifies the name of the executable of the partial linker with the options
  to be used, if any. If this attribute is not specified, then there is no
  partial linking. Example:

  .. code-block:: gpr

       for Library_Partial_Linker use ("gcc", "-nostdlib", "-Wl,-r", "-o");


.. _Shared_Library_Related_Attributes:

Shared Library Related Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* Shared_Library_Prefix

  Specifies the prefix of the file names of shared libraries. When this attribute
  is not specified, the prefix is `lib`. Example:

  .. code-block:: gpr

       for Shared_Library_Prefix use ""; --  for Windows, if needed

* Shared_Library_Suffix

  Specifies the suffix of the file names of shared libraries. When this attribute
  is not specified, the suffix is :file:`.so`. Example:

  .. code-block:: gpr

       for Shared_Library_Suffix use ".dll"; --  for Windows

* Symbolic_Link_Supported

  Specifies if symbolic links are supported by the platforms. The possible values
  of this attribute are `"false"` (the default) and `"true"`. When this attribute is
  not specified, symbolic links are not supported.

  .. code-block:: gpr

       for Symbolic_Link_Supported use "true";

* Library_Major_Minor_ID_Supported

  Specifies if major and minor IDs are supported for shared libraries.
  The possible values of this attribute are `"false"` (the default) and `"true"`.
  When this attribute is not specified, major and minor IDs are not supported.

  .. code-block:: gpr

       for Library_Major_Minor_ID_Supported use "True";

* Library_Auto_Init_Supported

  Specifies if library auto initialization is supported. The possible values of
  this attribute are `"false"` (the default) and `"true"`. When this attribute is not
  specified, library auto initialization is not supported.

  .. code-block:: gpr

       for Library_Auto_Init_Supported use "true";

* Shared_Library_Minimum_Switches

  Specifies the minimum options to be used when building a shared
  library. These options are put in the appropriate section in the
  library exchange file when the library builder is invoked. Example:

  .. code-block:: gpr

       for Shared_Library_Minimum_Switches use  ("-shared");

* Library_Version_Switches

  Specifies the option or options to be used when a library version is used.
  These options are put in the appropriate section in the library exchange file
  when the library builder is invoked. Example:

  .. code-block:: gpr

       for Library_Version_Switches use ("-Wl,-soname,");

* Runtime_Library_Dir (<language>)

  Specifies the directory for the runtime libraries for the language.
  Example:

  .. code-block:: gpr

       for Runtime_Library_Dir ("Ada") use "/path/to/adalib";

  This attribute is used by GPRlib to link shared libraries with Ada code.

* Object_Lister

  Specifies the name of the executable of the object lister with the
  minimum options, if any. This tool is used to list symbols out of
  object code to create a list of the symbols to export. Example:

  .. code-block:: gpr

       for Object_Lister use ("nm", "-g", "--demangle");

* Object_Lister_Matcher

  A regular expression pattern for matching symbols out of the output
  of Object_Lister tool. Example:

  .. code-block:: gpr

       for Object_Lister_Matcher use " T (.*)";

* Export_File_Format

  The export file format to generate, this is either DEF (Windows),
  Flat or GNU. Example:

  .. code-block:: gpr

       for Export_File_Format use "GNU";

* Export_File_Switch

  The required switch to pass the export file to the linker. Example:

  .. code-block:: gpr

       for Export_File_Switch use "-Wl,--version-script=";


.. _Package_Naming:

Package Naming
--------------

Attributes in package `Naming` of a configuration file specify defaults. These
attributes may be used in user project files to replace these defaults.

The following attributes usually appear in package `Naming` of a configuration
file:

* Spec_Suffix (<language>)

  Specifies the default suffix for a 'spec' or header file. Examples:

  .. code-block:: gpr

       for Spec_Suffix ("Ada") use ".ads";
       for Spec_Suffix ("C")   use ".h";
       for Spec_Suffix ("C++") use ".hh";

* Body_Suffix (<language>)

  Specifies the default suffix for a 'body' or a source file. Examples:

  .. code-block:: gpr

       for Body_Suffix ("Ada") use ".adb";
       for Body_Suffix ("C")   use ".c";
       for Body_Suffix ("C++") use ".cpp";

* Separate_Suffix

  Specifies the suffix for a subunit source file (separate) in Ada. If attribute
  `Separate_Suffix` is not specified, then the default suffix of subunit source
  files is the same as the default suffix for body source files. Example:

  .. code-block:: gpr

       for Separate_Suffix use ".sep";

* Casing

  Specifies the casing of spec and body files in a unit based language
  (such as Ada) to know how to map a unit name to its file name. The values for
  this attribute may only be `"lowercase"`, `"UPPERCASE"` and `"Mixedcase"`.
  The default, when attribute `Casing` is not specified is lower case.
  This attribute rarely needs to be specified, since on
  platforms where file names are not case sensitive (such as Windows or VMS)
  the default (lower case) will suffice.

* Dot_Replacement

  Specifies the string to replace a dot ('.') in unit names of a unit based
  language (such as Ada) to obtain its file name. If there is any unit based
  language in the configuration, attribute `Dot_Replacement` must be declared.
  Example:

  .. code-block:: gpr

       for Dot_Replacement use "-";


.. _Package_Builder:

Package Builder
---------------


* Executable_Suffix

  Specifies the default executable suffix. If no attribute `Executable_Suffix` is
  declared, then the default executable suffix for the host platform is used.
  Example:

  .. code-block:: gpr

       for Executable_Suffix use ".exe";


.. _Package_Compiler:

Package Compiler
----------------

.. _General_Compilation_Attributes:

General Compilation Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^


* Driver (<language>)

  Specifies the name of the executable for the compiler of a language. The single
  string value of this attribute may be an absolute path or a relative path. If
  relative, then the execution path is searched. Specifying the empty string for
  this attribute indicates that there is no compiler for the language.

  Examples:

  .. code-block:: gpr

       for Driver ("C++") use "g++";
       for Driver ("Ada") use "/.../bin/gcc";
       for Driver ("Project file") use "";

* Required_Switches (<language>)

  Specifies the minimum options that must be used when invoking the compiler
  of a language. Examples:

  .. code-block:: gpr

       for Required_Switches ("C")   use ("-c", "-x", "c");
       for Required_Switches ("Ada") use ("-c", "-x", "ada", "-gnatA");

* PIC_Option (<language>)

  Specifies the option or options that must be used when compiling a source of
  a language to be put in a shared library. Example:

  .. code-block:: gpr

       for PIC_Option ("C") use ("-fPIC");


.. _Mapping_File_Related_Attributes:

Mapping File Related Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* Mapping_File_Switches (<language>)

  Specifies the switch or switches to be used to specify a mapping file to the
  compiler. When attribute `Mapping_File_Switches` is not declared, then no
  mapping file is specified to the compiler. The value of this attribute is a
  string list. The path name of the mapping file is concatenated with the last
  string in the string list, which may be empty. Example:

  .. code-block:: gpr

       for Mapping_File_Switches ("Ada") use ("-gnatem=");

* Mapping_Spec_Suffix (<language>)

  Specifies, for unit based languages that support mapping files, the suffix in
  the mapping file that needs to be added to the unit name for specs. Example:

  .. code-block:: gpr

        for Mapping_Spec_Suffix ("Ada") use "%s";

* Mapping_Body_Suffix (<language>)

  Specifies, for unit based languages that support mapping files, the suffix in
  the mapping file that needs to be added to the unit name for bodies. Example:

  .. code-block:: gpr

        for Mapping_Spec_Suffix ("Ada") use "%b";


.. _Config_File_Related_Attributes:

Config File Related Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

In the value of config file attributes defined below, there are some
placeholders that GPRbuild will replace. These placeholders are:

=========== =====================
Placeholder Interpretation
----------- ---------------------
:samp:`%u`  unit name
:samp:`%f`  source file name
:samp:`%s`  spec suffix
:samp:`%b`  body suffix
:samp:`%c`  casing
:samp:`%d`  dot replacement string
=========== =====================


Attributes:

* Config_File_Switches (<language>)

  Specifies the switch or switches to be used to specify a configuration file to
  the compiler. When attribute `Config_File_Switches` is not declared, then no
  config file is specified to the compiler. The value of this attribute is a
  string list. The path name of the config file is concatenated with the last
  string in the string list, which may be empty. Example:

  .. code-block:: gpr

       for Config_File_Switches ("Ada") use ("-gnatec=");

* Config_Body_File_Name (<language>)

  Specifies the line to be put in a config file to indicate the file name of a
  body. Example:

  .. code-block:: gpr

       for Config_Body_File_Name ("Ada") use
           "pragma Source_File_Name_Project (%u, Body_File_Name => ""%f"");";

* Config_Spec_File_Name (<language>)

  Specifies the line to be put in a config file to indicate the file name of a
  spec. Example:

  .. code-block:: gpr

       for Config_Spec_File_Name ("Ada") use
           "pragma Source_File_Name_Project (%u, Spec_File_Name => ""%f"");";

* Config_Body_File_Name_Pattern (<language>)

  Specifies the line to be put in a config file to indicate a body file name
  pattern. Example:

  .. code-block:: gpr

       for Config_Body_File_Name_Pattern ("Ada") use
           "pragma Source_File_Name_Project " &
           "  (Body_File_Name  => ""*%b""," &
           "   Casing          => %c," &
           "   Dot_Replacement => ""%d"");";

* Config_Spec_File_Name_Pattern (<language>)

  Specifies the line to be put in a config file to indicate a spec file name
  pattern. Example:

  .. code-block:: gpr

       for Config_Spec_File_Name_Pattern ("Ada") use
           "pragma Source_File_Name_Project " &
           "  (Spec_File_Name  => ""*%s""," &
           "   Casing          => %c," &
           "   Dot_Replacement => ""%d"");";

* Config_File_Unique (<language>)

  Specifies, for languages that support config files, if several config files
  may be indicated to the compiler, or not. This attribute may have only two
  values: `"true"` or `"false"` (case insensitive). The default, when this attribute
  is not specified, is `"false"`. When the value `"true"` is specified for this
  attribute, GPRbuild will concatenate the config files, if there are more than
  one. Example:

  .. code-block:: gpr

       for Config_File_Unique ("Ada") use "True";


.. _Dependency_Related_Attributes:

Dependency Related Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

There are two dependency-related attributes: `Dependency_Switches` and
`Dependency_Driver`. If neither of these two attributes are specified for
a language other than Ada, then the source needs to be (re)compiled if
the object file does not exist or the source file is more recent than
the object file or the switch file.

* Dependency_Switches (<language>)

  For languages other than Ada, attribute `Dependency_Switches` specifies
  the option or options to add to the compiler invocation so that it creates
  the dependency file at the same time. The value of attribute `Dependency_Option`
  is a string list. The name of the dependency file is added to the last string
  in the list, which may be empty. Example:

  .. code-block:: gpr

       for Dependency_Switches ("C") use ("-Wp,-MD,");

  With these `Dependency_Switches`, when compiling :file:`file.c` the compiler will be
  invoked with the option :samp:`-Wp,-MD,file.d`.

* Dependency_Driver (<language>)

  Specifies the command and options to create a dependency file for a source.
  The full path name of the source is appended to the last string of the string
  list value. Example:

  .. code-block:: gpr

       for Dependency_Driver ("C") use ("gcc", "-E", "-Wp,-M", "");

  Usually, attributes `Dependency_Switches` and `Dependency_Driver` are not both
  specified.


.. _Search_Path_Related_Attributes:

Search Path Related Attributes
^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^

* Include_Switches (<language>)

  Specifies the option or options to use when invoking the compiler to indicate
  that a directory is part of the source search path. The value of this
  attribute is a string list. The full path name of the directory is concatenated
  with the last string in the string list, which may be empty. Example:

  .. code-block:: gpr

       for Include_Switches ("C") use ("-I");

  Attribute `Include_Switches` is ignored if either one of the attributes
  `Include_Path` or `Include_Path_File` are specified.

* Include_Path (<language>)

  Specifies the name of an environment variable that is used by the compiler to
  get the source search path. The value of the environment variable is the source
  search path to be used by the compiler. Example:

  .. code-block:: gpr

       for Include_Path ("C")   use "CPATH";
       for Include_Path ("Ada") use "ADA_INCLUDE_PATH";

  Attribute `Include_Path` is ignored if attribute `Include_Path_File` is declared
  for the language.

* Include_Path_File (<language>)

  Specifies the name of an environment variable that is used by the compiler to
  get the source search path. The value of the environment variable is the path
  name of a text file that contains the path names of the directories of the
  source search path. Example:

  .. code-block:: gpr

       for Include_Path_File ("Ada") use "ADA_PRJ_INCLUDE_FILE";


.. _Package_Binder:

Package Binder
--------------

* Driver (<language>)

  Specifies the name of the executable of the binder driver. When this attribute
  is not specified, there is no binder for the language. Example:

  .. code-block:: gpr

       for Driver ("Ada") use "/.../gprbind";

* Required_Switches (<language>)

  Specifies the minimum options to be used when invoking the binder driver.
  These options are put in the appropriate section in the binder exchange file,
  one option per line. Example:

  .. code-block:: gpr

       for Required_Switches ("Ada") use ("--prefix=<prefix>");

* Prefix (<language>)

  Specifies the prefix to be used in the name of the binder exchange file.
  Example:

  .. code-block:: gpr

       for Prefix ("C++") use ("c__");

* Objects_Path (<language>)

  Specifies the name of an environment variable that is used by the compiler to
  get the object search path. The value of the environment variable is the object
  search path to be used by the compiler. Example:

  .. code-block:: gpr

       for Objects_Path ("Ada") use "ADA_OBJECTS_PATH";

* Objects_Path_File (<language>)

  Specifies the name of an environment variable that is used by the compiler to
  get the object search path. The value of the environment variable is the path
  name of a text file that contains the path names of the directories of the
  object search path. Example:

  .. code-block:: gpr

       for Objects_Path_File ("Ada") use "ADA_PRJ_OBJECTS_FILE";


.. _Package_Linker:

Package Linker
--------------

* Driver

  Specifies the name of the executable of the linker. Example:

  .. code-block:: gpr

       for Driver use "g++";

* Required_Switches

  Specifies the minimum options to be used when invoking the linker. Those
  options are happened at the end of the link command so that potentially
  conflicting user options take precedence.

* Map_File_Option

  Specifies the option to be used when the linker is asked to produce
  a map file.

  .. code-block:: gpr

       for Map_File_Option use "-Wl,-Map,";

* Max_Command_Line_Length

  Specifies the maximum length of the command line to invoke the linker.
  If this maximum length is reached, a response file will be used to shorten
  the length of the command line. This is only taken into account when
  attribute Response_File_Format is specified.

  .. code-block:: gpr

       for Max_Command_Line_Length use "8000";

* Response_File_Format

  Specifies the format of the response file to be generated when the maximum
  length of the command line to invoke the linker is reached. This is only
  taken into account when attribute Max_Command_Line_Length is specified.

  The allowed case-insensitive values are:

  * "GNU"
     Used when the underlying linker is gnu ld.

  * "Object_List"
     Used when the response file is a list of object files, one per line.

  * "GCC_GNU"
     Used with recent version of gcc when the underlined linker is gnu ld.

  * "GCC_Object_List"
     Used with recent version of gcc when the underlying linker is not gnu ld.

  .. code-block:: gpr

       for Response_File_Format use "GCC_GNU";

* Response_File_Switches

  Specifies the option(s) that must precede the response file name when
  when invoking the linker. This is only taken into account when both
  attributes Max_Command_Line_Length and Response_File_Format are specified.

  .. code-block:: gpr

        for Response_File_Switches  use ("-Wl,-f,");


.. _Cleaning_up_with_GPRclean:

Cleaning up with GPRclean
=========================

The GPRclean tool removes the files created by GPRbuild.
At a minimum, to invoke GPRclean you must specify a main project file
in a command such as `gprclean proj.gpr` or `gprclean -P proj.gpr`.

Examples of invocation of GPRclean:

.. code-block:: gpr

     gprclean -r prj1.gpr
     gprclean -c -P prj2.gpr


.. _Switches_for_GPRclean:

Switches for GPRclean
---------------------

The switches for GPRclean are:

* :samp:`--no-project`

  This switch cannot be used if a project file is specified on the command
  line.

  When this switch is specified, it indicates to gprclean that the project
  files in the current directory should not be considered and that the default
  project file in <prefix>/share/gpr is to be used.

  It is usually used with one or several mains specified on the command line.

* :samp:`--distributed`

  Also clean-up the sources on build slaves,
  see :ref:`Distributed_compilation`.

* :samp:`--slave-env={name}`

  Use `name` as the slave's environment directory instead of the default one.
  This options is only used in distributed mode.

* :samp:`--config={config project file name}`

  Specify the configuration project file name.

* :samp:`--autoconf={config project file name}`

  This specifies a configuration project file name that already exists or will
  be created automatically. Option :samp:`--autoconf=`
  cannot be specified more than once. If the configuration project file
  specified with :samp:`--autoconf=` exists, then it is used. Otherwise,
  GPRconfig is invoked to create it automatically.

* :samp:`--target={targetname}`

  Specify a target for cross platforms.

* :samp:`--db {dir}`

  Parse `dir` as an additional knowledge base.

* :samp:`--db-`

  Do not parse the standard knowledge base.

* :samp:`--RTS={runtime}`

  Use runtime `runtime` for language Ada.

* :samp:`--RTS:{lang}={runtime}`

  Use runtime `runtime` for language `lang`.

* :samp:`--subdirs={dir}`

  This indicates that the object, library and executable directories specified
  in the project file will be suffixed with {subdir}. If needed, those
  subdirectories are created except for externally built projects: in this case
  if the subdirectories already exist they are used, otherwise the base
  directories are used.

* :samp:`--src-subdirs={subdir}`

  This adds the given subdirectory (relative to each object directory of the
  project tree) to the list of source directories of the project, one directory
  per object directory. GPRclean will remove the project source files found
  in these subdirectories. This option may be combined with :samp:`--subdirs`.

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

  Shared library projects may import any project.

* :samp:`-aP{dir}`

  Add directory `dir` to the project search path.

* :samp:`-c`

  Only delete compiler-generated files. Do not delete
  executables and libraries.

* :samp:`-eL`

  Follow symbolic links when processing project files.

* :samp:`-f`

  Force deletions of unwritable files.

* :samp:`-F`

  Display full project path name in brief error messages.

* :samp:`-h`

  Display the usage.

* :samp:`-n`

  Do not delete files, only list files that would be deleted.

* :samp:`-P{proj}`

  Use Project File `proj`.

* :samp:`-q`

  Be quiet/terse. There is no output, except to report problems.

* :samp:`-r`

  Recursive. Clean all projects referenced by the main
  project directly or indirectly. Without this switch, GPRclean only
  cleans the main project.

* :samp:`-v`

  Verbose mode.

* :samp:`-vP{x}`

  Specify verbosity when parsing Project Files.
  `x` = 0 (default), 1 or 2.

* :samp:`-Xnm={val}`

  Specify an external reference for Project Files.


.. _Installing_with_GPRinstall:

Installing with GPRinstall
==========================

The GPRinstall tool installs projects. With GPRinstall it is not
needed to create complex `makefiles` to install the components. This
also removes the need for OS specific commands (like `cp`,
`mkdir` on UNIXs) and so makes the installation process easier on
all supported platforms.

After building a project it is often necessary to install the project to
make it accessible to other projects. GPRinstall installs only what is
necessary and nothing more. That is, for a library project the library
itself is installed with the corresponding ALI files for Ada
sources, but the object code is not installed as it not needed. Also if
the Ada specs are installed the bodies are not, because they are not needed
in most cases. The cases where the bodies are required (if the spec has inline
routines or is a generic) are properly detected by GPRinstall.

Furthermore, we can note that GPRinstall handles the preprocessed
sources. So it installs the correct variant of the source after resolving
the preprocessing directives.

The parts of a project that can be installed are:

* sources of a project

* a static or shared library built from a library project

* objects built from a standard project

* executables built from a standard project

Moreover, GPRinstall will create, when needed, a project to use the installed
sources, objects or library. By default, this project file is installed in the
GPRbuild's default path location so that it can be "with"ed easily without
further configuration. The installation process keeps record of every file
installed for easy and safe removal.

GPRinstall supports all kinds of project:

* standard projects

  The object files, executable and source files are considered for installation.

* library and aggregate library projects

  The library itself and the source files are considered for installation.

* aggregate projects

  All aggregated projects are considered for installation.


Projects that won't be installed are:

* Project explicitly disabled for installation

  A project with the Active attribute set to False in the project's
  Install package.

* Projects with no sources

  Both abstract projects and standard projects without any sources

At a minimum, to invoke GPRinstall you must specify a main project file in a
command such as ``gprinstall proj.gpr`` or ``gprinstall -P proj.gpr`` (in
installing mode) or the install name (in uninstalling mode)
``gprinstall --uninstall proj``.

Examples of invocation of GPRinstall:

::

     gprinstall prj1.gpr
     gprinstall -r --prefix=/my/root/install -P prj2.gpr

GPRinstall will record the installation under the *install name* which is by
default the name of the project without the extension. That is above the
project install names are ``prj1`` and ``prj2``.

The installation name can be specified with the option ``--install-name``. This
makes it possible to record the installation of multiple projects under the
same name. This is handy if an application comes with a library and a set of
tools built with multiple projects. In this case we may want to record the
installation under the same name. The install name is also used as a suffix to
group include and library directories.

Examples of installation under the same name:

::

     gprinstall --install-name=myapp lib.gpr
     gprinstall --install-name=myapp --mode=usage tools/tools.gpr

Note the ``--mode=usage`` option above. This tells GPRinstall to only install
the executable built as part of the project.

It is possible to uninstall a project by using the ``--uninstall`` option. In
this case we just pass the install name to GPRinstall:

::

     gprinstall --uninstall prj1
     gprinstall --uninstall prj2

And both ``lib.gpr`` and ``tools.gpr`` above will be uninstalled with:

::

     gprinstall --uninstall myapp


Note that GPRinstall does not deal with dependencies between projects. Also
GPRinstall in uninstall mode does not need nor use information in the installed
project. This is because the project may not be present anymore and many
different project scenario may have been installed. So when uninstalling
GPRinstall just use the manifest file (whose name is the install name)
information.


.. _Switches_for_GPRinstall:

Switches for GPRinstall
-----------------------

The switches for GPRinstall are:

* :samp:`--config={main config project file name}`

  Specify the configuration project file name

* :samp:`--autoconf={config project file name}`

  This specifies a configuration project file name that already exists or will
  be created automatically. Option :samp:`--autoconf=`
  cannot be specified more than once. If the configuration project file
  specified with :samp:`--autoconf=` exists, then it is used. Otherwise,
  GPRconfig is invoked to create it automatically.

* :samp:`--build-name`

  Specify under which name the current
  project build must be installed. The default value is
  `default`. Using this option it is possible to install different
  builds (using different configuration, options, etc...) of the same
  project. The given name will be used by client to select which build
  they want to use (link against).

* :samp:`--build-var`

  Specify the name of the build variable in the installed project.
  If this options is not used, the default build variable used is
  ``<PROJECT_NAME>_BUILD``.

  It is possible to specify multiple variables in --build-var
  option. In this case, if the first build variable is not found, the
  second one will be checked, and so on. This makes it possible to
  have a project specific variable to select the corresponding build
  and a more generic build variable shared by multiple projects.

  ::

      $ gprinstall -Pproject1 \
        --build-var=PROJECT1_BUILD,LIBRARY_TYPE
                    ^
                    Scenario variable to control
                    specifically this project

                                   ^
                                   Scenario variable to control
                                   the default for a set of projects

      $ gprinstall -Pproject2 \
        --build-var=PROJECT2_BUILD,LIBRARY_TYPE

* :samp:`--no-build-var`

  Specify that no build/scenario
  variable should be generated. This option can be use for a project
  where there is single configuration, so a single installation. This
  option cannot be used with :samp:`--build-var`.

* :samp:`--dry-run`

  Install nothing, just display the actions
  that would have been done.

* :samp:`-a`

  Install all the sources (default). Cannot be used with ``-m`` below.

* :samp:`-m`

  Install only the interface sources (minimal set of sources). Cannot
  be used with ``-a`` above.

* :samp:`-f`

  Force overwriting of existing files

* :samp:`-h`

  Display this message

* :samp:`--mode=[dev/usage]`

  Specify the installation mode.

  * dev

    This is the default mode. The installation is done in developer
    mode. All files to use the project are copied to install prefix. For a
    library this means that the specs, the corresponding ALI files for
    Ada units and the library itself (static or relocatable) are
    installed. For a standard project the object files are installed
    instead of the library.

  * usage

    The installation is done in usage mode. This means that only the
    library or the executable is installed. In this installation mode
    there is no project generated, nor specs or ALI files installed.

  ======== ================================================================
  Mode     Interpretation
  -------- ----------------------------------------------------------------
  `dev`    For this mode the binaries (built libraries and
           executable) are installed together with the sources to use them.
  `usage`  For this mode only the binaries are installed and no project are
           created.
  ======== ================================================================

* :samp:`-p`, :samp:`--create-missing-dirs`

  Create missing directories in the installation location.

* :samp:`-P{proj}`

  Specify the project file to install.

* :samp:`--prefix={path}`

  Specify the location of the installation.
  If not specified, the default location for the current
  compiler is used. That is, ``path`` corresponds to parent directory
  where ``gprinstall`` is found.

* :samp:`--install-name={name}`

  Specify the name to use for recording the installation.
  The default is the project name without the extension. If set this
  option is also used as include or library directories' suffix to
  group all related installations under a common directory.

* :samp:`--sources-subdir={path}`

  Specify the value for the sources installation directory if an absolute path.
  Otherwise it is appended to the prefix above. The default is
  ``include/<project_name>[.<build-name>]``

* :samp:`--lib-subdir={path}`

  Specify the value for the library and object installation
  directory if an absolute path.
  Otherwise it is appended to the prefix above. The default is
  ``lib/<project_name>[.<build-name>]``

* :samp:`--link-lib-subdir={path}`

  Specify the value for the
  library symlink directory if an absolute path. Otherwise it is
  appended to the prefix above.

* :samp:`---exec-subdir={path}`

  Specify the value for the
  executables installation directory if an absolute path. Otherwise it is
  appended to the prefix above. The default is ``bin``.

* :samp:`--project-subdir={path}`

  Specify the value for the
  project installation directory if an absolute path. Otherwise it is
  appended to the prefix above. The default is ``share/gpr``.

* :samp:`--no-project`

  Specify that no project is to be generated and installed.

* :samp:`--target={targetname}`

  Specify a target for cross platforms.

* :samp:`--no-lib-link`

  Disable copy of shared libraries into
  the executable directory on Windows or creation of symlink in the lib
  directory on UNIX. This is done by default to place the shared
  libraries into a directory where application will look for them.

* :samp:`--sources-only`

  Copy only sources part of the project,
  the object, library or executable files are never copied. When this
  switch is used the installed project is not set as externally built.

* :samp:`--side-debug`

  Write debug symbols out of executables and libraries into a
  separate file. The separate file is named after the main file with
  an added ``.debug`` extension. That is, if the executable to be
  installed is named ``main``, then a file ``main.debug`` is also created in
  the same location, containing only the debug information. The
  debug information is then removed from the ``main`` executable.

* :samp:`--subdirs={subdir}`

  This indicates that the object, library and executable directories specified
  in the project file will be suffixed with {subdir}. If needed, those
  subdirectories are created except for externally built projects: in this case
  if the subdirectories already exist they are used, otherwise the base
  directories are used.

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

* :samp:`-q`

  Be quiet/terse. There is no output, except to report problems.

* :samp:`-r`

  (Recursive.) Install all projects referenced by the main
  project directly or indirectly. Without this switch, GPRinstall only
  installs the main project.

* :samp:`--no-manifest`

  Prevent the manifest file from being created. Note that using this
  option will make it impossible to uninstall the project using
  GPRinstall. See option `--uninstall`.

* :samp:`--uninstall`

  Uninstall mode, files installed for a given project or install name
  will be removed. A check is done that no manual changes have been
  applied to the files before removing.  Deletion of the files can be
  forced in this case by using the :samp:`-f` option. Note that the
  parameter in this case is not the project name but the install name which
  corresponds to the manifest file.

* :samp:`--list`

  List mode, displays all the installed packaged.

* :samp:`--stat`

  Apply to list mode above, displays also some
  statistics about the installed packages : number of files, total size
  used on disk, and whether there is some files missing.

* :samp:`-v`

  Verbose mode

* :samp:`-Xnm={val}`

  Specify an external reference for Project Files.


.. _Specifying_a_Naming_Scheme_with_GPRname:

Specifying a Naming Scheme with GPRname
=======================================

When the Ada source file names do not follow a regular naming
scheme, the mapping of Ada units to source file names must be indicated
in package Naming with attributes Spec and Body.

To help maintain the correspondence between compilation unit names and
source file names within the compiler,
the tool `gprname` may be used to generate automatically these attributes.



.. _Running_gprname:

Running `gprname`
-----------------

The usual form of the `gprname` command is:

.. code-block:: sh

      $ gprname [`switches`] `naming_pattern` [`naming_patterns`]
          [--and [`switches`] `naming_pattern` [`naming_patterns`]]


Most of the arguments are optional: switch *-P* must be specified to indicate
the project file and at least one Naming Pattern.

`gprname` will attempt to
find all the compilation units in files that follow at least one of the
naming patterns. To find Ada compilation units,
`gprname` will use the GNAT compiler in syntax-check-only mode on all
regular files.

One or several Naming Patterns may be given as arguments to `gprname`.
Each Naming Pattern is enclosed between double quotes (or single
quotes on Windows).
A Naming Pattern is a regular expression similar to the wildcard patterns
used in file names by the Unix shells or the DOS prompt.

`gprname` may be called with several sections of directories/patterns.
Sections are separated by switch `--and`. In each section, there must be
at least one pattern. If no directory is specified in a section, the
project directory is implied.
The options other that the directory switches and the patterns apply globally
even if they are in different sections.

Examples of Naming Patterns are::

     "*.[12].ada"
     "*.ad[sb]*"
     "body_*"    "spec_*"

For a more complete description of the syntax of Naming Patterns,
see the second kind of regular expressions described in :file:`g-regexp.ads`
(the 'Glob' regular expressions).

.. _Switches_for_pgprname:

Switches for GPRname
---------------------

Switches for `gprname` must precede any specified Naming Pattern.

You may specify any of the following switches to `gprname`:

.. index:: --version (gprname)

* :samp:`--version`

  Display Copyright and version, then exit disregarding all other options.

.. index:: --target= (gprname)

* :samp:`--target=<targ>`

  Indicates the target of the GNAT compiler. This may be needed if there is
  no native compiler available.

.. index:: --help (gprname)

* :samp:`--help`

  If *--version* was not used, display usage, then exit disregarding
  all other options.

* :samp:`--subdirs={dir}`

  This indicates that the object, library and executable directories specified
  in the project file will be suffixed with {subdir}. If needed, those
  subdirectories are created except for externally built projects: in this case
  if the subdirectories already exist they are used, otherwise the base
  directories are used.

* :samp:`--no-backup`

  Do not create a backup copy of the project file if it already exists.

* :samp:`--ignore-duplicate-files`

  Ignore files with the same basename, and take the first one found into
  account only. By default when encountering a duplicate file, a warning is
  emitted, and duplicate entries in the `Naming` package will be generated,
  needing manual editing to resolve the conflict. With this switch, gprname
  assumes that only the first file should be used and others should be
  ignored.

* :samp:`--ignore-predefined-units`

  Ignore predefined units (children of System, Interfaces and Ada packages).

* :samp:`--and`

  Start another section of directories/patterns.

.. index:: -d (gprname)

* :samp:`-d{dir}`

  Look for source files in directory :file:`dir`. There may be zero, one or more
  spaces between *-d* and :file:`dir`.
  :file:`dir` may end with `/**`, that is it may be of the form
  `root_dir/**`. In this case, the directory `root_dir` and all of its
  subdirectories, recursively, have to be searched for sources.
  When a switch *-d*
  is specified, the current working directory will not be searched for source
  files, unless it is explicitly specified with a *-d*
  or *-D* switch.
  Several switches *-d* may be specified.
  If :file:`dir` is a relative path, it is relative to the directory of
  the project file specified with switch *-P*. The directory
  specified with switch *-d* must exist and be readable.

.. index:: -D (gprname)

* :samp:`-D{filename}`

  Look for source files in all directories listed in text file :file:`filename`.
  There may be zero, one or more spaces between *-D*
  and :file:`filename`.
  :file:`filename` must be an existing, readable text file.
  Each nonempty line in :file:`filename` must be a directory.
  Specifying switch *-D* is equivalent to specifying as many
  switches *-d* as there are nonempty lines in
  :file:`file`.

* :samp:`-eL`

  Follow symbolic links when processing project files.

  .. index:: -f (gprname)

* :samp:`-f{pattern}`

  Foreign C language patterns. Using this switch, it is possible to add sources
  of language C to the list of sources of a project file.

  For example,

  .. code-block:: sh

     gprname -P prj.gpr -f"*.c" "*.ada" -f "*.clang"

  will look for Ada units in all files with the :file:`.ada` extension,
  and will add to the list of file for project :file:`prj.gpr` the C files
  with extensions :file:`.c` and :file:`.clang`. Attribute Languages will be
  declared with the list of languages with sources. In the above example,
  it will be ("Ada", "C") if Ada and C sources have been found.

* :samp:`-f:{<lang>} {pattern}`

  Foreign language {<lang>} patterns. Using this switch, it is possible to add
  sources of language <lang> to the list of sources of a project file.

  For example,

  .. code-block:: sh

     gprname -P prj.gpr "*.ada" -f:C++ "*.cpp" -f:C++ "*.CPP"

  Files with extensions :file:`.cpp` and :file:`*.CPP` are C++ sources.
  Attribute Languages will have value ("Ada", "C++") if Ada and C++ sources
  are found.

  .. index:: -h (gprname)

* :samp:`-h`

  Output usage (help) information. The output is written to :file:`stdout`.

  .. index:: -P (gprname)

* :samp:`-P{proj}`

  Create or update project file :file:`proj`. There may be zero, one or more
  space between *-P* and :file:`proj`. :file:`proj` may include directory
  information. :file:`proj` must be writable.
  There must be only one switch *-P*.
  If switch *--no-backup* is not specified, a backup copy of the project file is created
  in the project directory with file name <proj>.gpr.saved_x. 'x' is the first
  non negative number that makes this backup copy a new file.

  .. index:: -v (gprname)

* :samp:`-v`

  Verbose mode. Output detailed explanation of behavior to :file:`stdout`.
  This includes name of the file written, the name of the directories to search
  and, for each file in those directories whose name matches at least one of
  the Naming Patterns, an indication of whether the file contains a unit,
  and if so the name of the unit.

.. index:: -v -v (gprname)

* :samp:`-v -v`

  Very Verbose mode. In addition to the output produced in verbose mode,
  for each file in the searched directories whose name matches none of
  the Naming Patterns, an indication is given that there is no match.

  .. index:: -x (gprname)

* :samp:`-x{pattern}`

  Excluded patterns. Using this switch, it is possible to exclude some files
  that would match the name patterns. For example,

  .. code-block:: sh

      gprname -P prj.gpr -x "*_nt.ada" "*.ada"

  will look for Ada units in all files with the :file:`.ada` extension,
  except those whose names end with :file:`_nt.ada`.

.. _Example_of_gprname_Usage:

Example of `gprname` Usage
--------------------------

.. code-block:: sh

     $ gprname -P/home/me/proj.gpr -x "*_nt_body.ada"
     -dsources -dsources/plus -Dcommon_dirs.txt "body_*" "spec_*"

Note that several switches *-d* may be used,
even in conjunction with one or several switches
*-D*. Several Naming Patterns and one excluded pattern
are used in this example.

.. _The_Library_Browser_gprls:

The Library Browser GPRls
=========================

.. index:: Library browser
.. index:: ! gprls

`gprls` is a tool that outputs information about compiled sources. It gives the
relationship between objects, unit names and source files. It can also be used
to check source dependencies as well as various characteristics.

.. _Running_gprls:

Running `gprls`
----------------

The `gprls` command has the form

  ::

      $ gprls switches `object_or_dependency_files`

The main argument is the list of object files or :file:`ali` files for Ada
sources for which information is requested.

`gprls` uses a project file, either specified through a single switch -P,
or the default project file. If no `object_or_dependency_files` is specified
then all the object files corresponding to the sources of the project are
deemed to be specified. If `object_or_dependency_files` is specified for
an aggregate project and there is more than one such file in different
aggregated projects then the file found first is used to show the information.

In normal mode, without option other that -P <project file>, `gprls` produces
information for each object/dependency file: the full path of the object,
the name of the principal unit in this object if the source is in Ada,
the status of the source and the full path of the source.

Here is a simple example of use:


  ::

     $ gprls -P prj.gpr
     /my_path/obj/pkg.o
        pkg
          DIF pkg.adb
     /my_path/obj/main.o
        main
          MOK main.adb

The first three lines can be interpreted as follows: the main unit which is
contained in
object file :file:`pkg.o` is pkg, whose main source is in
:file:`pkg.adb`. Furthermore, the version of the source used for the
compilation of pkg has been modified (DIF). Each source file has a status
qualifier which can be:

*OK (unchanged)*
  The version of the source file used for the compilation of the
  specified unit corresponds exactly to the actual source file.

*MOK (slightly modified)*
  The version of the source file used for the compilation of the
  specified unit differs from the actual source file but not enough to
  require recompilation. If you use `gprbuild` with the qualifier
  *-m (minimal recompilation)*, a file marked
  MOK will not be recompiled.

*DIF (modified)*
  The source used to build this object has been modified and need to be
  recompiled.

*??? (dependency file not found)*
  The object/dependency file cannot be found.


.. _Switches_for_gprls:

Switches for GPRls
------------------

`gprls` recognizes the following switches:


.. index:: --version (gprls)

:samp:`--version`
  Display Copyright and version, then exit disregarding all other options.


.. index:: --help (gprls)

:samp:`--help`
  If *--version* was not used, display usage, then exit disregarding
  all other options.

.. index:: --closure (gprls)

:samp:`--closure`
  Display the Ada closures of the mains specified on the command line or
  in attribute Main of the main project. The absolute paths of the units in
  the closures are listed, but no status is checked. If all the ALI files are
  found, then the list is preceded with the line "Closure:" or "Closures:".
  Otherwise, it is preceded with the line "Incomplete Closure:" or
  "Incomplete closures:".

.. index:: -P (gprls)

:samp:`-P <project file>`
  Use this project file. This switch may only be specified once.


.. index:: -a (gprls)

:samp:`-a`
  Consider all units, including those of the predefined Ada library.
  Especially useful with *-d*.


.. index:: -d (gprls)

:samp:`-d`
  List sources from which specified units depend on.


.. index:: -h (gprls)

:samp:`-h`
  Output the list of options.


.. index:: -o (gprls)

:samp:`-o`
  Only output information about object files.


.. index:: -s (gprls)

:samp:`-s`
  Only output information about source files.


.. index:: -u (gprls)

:samp:`-u`
  Only output information about compilation units.


.. index:: -U (gprls)

:samp:`-U`
  If no object/dependency file is specified, list information for the sources
  of all the projects in the project tree.


.. index:: -files (gprls)

:samp:`-files={file}`
  Take as arguments the files listed in text file `file`.
  Text file `file` may contain empty lines that are ignored.
  Each nonempty line should contain the name of an existing object/dependency
  file.
  Several such switches may be specified simultaneously.


.. index:: -aP (gprls)

:samp:`-aP{dir}`
  Add `dir` at the beginning of the project search dir.


.. index:: --RTS (gprls)

:samp:`--RTS={rts-path}``
  Specifies the default location of the Ada runtime library.
  Same meaning as the equivalent *gprbuild* switch.


.. index:: -v (gprls)

:samp:`-v`
  Verbose mode. Output the complete source, object and project paths.
  For each Ada source, include special characteristics such as:

  * *Preelaborable*: The unit is preelaborable in the Ada sense.

  * *No_Elab_Code*:  No elaboration code has been produced by the compiler for this unit.

  * *Pure*: The unit is pure in the Ada sense.

  * *Elaborate_Body*: The unit contains a pragma Elaborate_Body.

  * *Remote_Types*: The unit contains a pragma Remote_Types.

  * *Shared_Passive*: The unit contains a pragma Shared_Passive.

  * *Predefined*: This unit is part of the predefined environment and cannot be modified
    by the user.

  * *Remote_Call_Interface*: The unit contains a pragma Remote_Call_Interface.


.. _Example_of_gprls_Usage:

Examples of `gprls` Usage
-------------------------

  ::

      $ gprls -v -P prj.gpr

       5 lines: No errors
      gprconfig --batch -o /my_path/obj/auto.cgpr --target=x86_64-linux --config=ada,,
      Creating configuration file: /my_path/obj/auto.cgpr
      Checking configuration /my_path/obj/auto.cgpr

      GPRLS Pro 17.0 (20161010) (x86_64-unknown-linux-gnu)
      Copyright (C) 2015-2016, AdaCore

      Source Search Path:
         <Current directory>
         /my_path/local/lib/gcc/x86_64-pc-linux-gnu/4.9.4//adainclude/

      Object Search Path:
         <Current directory>
         /my_path/local/lib/gcc/x86_64-pc-linux-gnu/4.9.4//adalib/

      Project Search Path:
         <Current_Directory>
         /my_path/local/x86_64-unknown-linux-gnu/lib/gnat
         /my_path/local/x86_64-unknown-linux-gnu/share/gpr
         /my_path/local/share/gpr
         /my_path/local/lib/gnat

      /my_path/obj/pkg.o
         Unit =>
           Name   => pkg
           Kind   => package body
           Flags  => No_Elab_Code
         Source => pkg.adb unchanged
         Unit =>
           Name   => pkg
           Kind   => package spec
           Flags  => No_Elab_Code
         Source => pkg.ads unchanged
      /my_path/obj/main.o
         Unit =>
           Name   => main
           Kind   => subprogram body
           Flags  => No_Elab_Code
         Source => main.adb slightly modified

      $ gprls -d -P prj.gpr main.o
      /my_path/obj/main.o
         main
             MOK main.adb

              OK pkg.ads

      $ gprls -s -P prj.gpr main.o
         main
      main.adb
