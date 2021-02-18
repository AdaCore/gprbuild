------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2021, Free Software Foundation, Inc.         --
--                                                                          --
-- This library is free software;  you can redistribute it and/or modify it --
-- under terms of the  GNU General Public License  as published by the Free --
-- Software  Foundation;  either version 3,  or (at your  option) any later --
-- version. This library is distributed in the hope that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE.                            --
--                                                                          --
-- As a special exception under Section 7 of GPL version 3, you are granted --
-- additional permissions described in the GCC Runtime Library Exception,   --
-- version 3.1, as published by the Free Software Foundation.               --
--                                                                          --
-- You should have received a copy of the GNU General Public License and    --
-- a copy of the GCC Runtime Library Exception along with this program;     --
-- see the files COPYING3 and COPYING.RUNTIME respectively.  If not, see    --
-- <http://www.gnu.org/licenses/>.                                          --
--                                                                          --
------------------------------------------------------------------------------

pragma Warnings (Off);
with System.WCh_Con; use System.WCh_Con;
pragma Warnings (On);

package GPR.Opt is

   Brief_Output : Boolean := False;
   --  Force brief error messages to standard error, even if verbose mode is
   --  set (so that main error messages go to standard output).

   ----------------------
   -- Checksum Control --
   ----------------------

   --  Checksums are computed for sources to check for sources being the same
   --  from a compilation point of view (e.g. spelling of identifiers and
   --  white space layout do not count in this computation).

   --  The way the checksum is computed has evolved across the various versions
   --  of GNAT. When gprbuild is called with -m, the checksums must be computed
   --  the same way in gprbuild as it was in the GNAT version of the compiler.
   --  The different ways are

   --    Version 6.4 and later:

   --      The Accumulate_Token_Checksum procedure is called after each numeric
   --      literal and each identifier/keyword. For keywords, Tok_Identifier is
   --      used in the call to Accumulate_Token_Checksum.

   --    Versions 5.04 to 6.3:

   --      For keywords, the token value were used in the call to procedure
   --      Accumulate_Token_Checksum. Type Token_Type did not include Tok_Some.

   --    Versions 5.03:

   --      For keywords, the token value were used in the call to
   --      Accumulate_Token_Checksum. Type Token_Type did not include
   --      Tok_Interface, Tok_Overriding, Tok_Synchronized and Tok_Some.

   --    Versions 5.02 and before:

   --      No calls to procedure Accumulate_Token_Checksum (the checksum
   --      mechanism was introduced in version 5.03).

   --  To signal to the scanner whether Accumulate_Token_Checksum needs to be
   --  called and what versions to call, the following Boolean flags are used:

   Checksum_Accumulate_Token_Checksum : Boolean := True;
   --  Set to False by gprbuild when the version of GNAT is 5.02 or before. If
   --  this switch is False, then we do not call Accumulate_Token_Checksum, so
   --  the setting of the following two flags is irrelevant.

   Checksum_GNAT_6_3 : Boolean := False;
   --  Set to True by gprbuild when the version of GNAT is 6.3 or before.

   Checksum_GNAT_5_03 : Boolean := False;
   --  Set to True by gprbuild when the version of GNAT is 5.03 or before.

   Compile_Only : Boolean := False;
   --  GPBUILD:
   --    set True to skip bind and link steps (except when Bind_Only is True)
   --  GPRCLEAN:
   --    set True to delete only the files produced by the compiler but not the
   --    library files or the executable files.

   Bind_Only : Boolean := False;
   --  Set to True to skip compile and link steps
   --  (except when Compile_Only and/or Link_Only are True).

   Check_Switches : Boolean := False;
   --  Set to True to check compiler options during the make process

   CodePeer_Mode : Boolean := False;
   --  Enable full CodePeer mode (SCIL generation, disable switches that
   --  interact badly with it, etc...). This is turned on by -gnatC.

   Directories_Must_Exist_In_Projects : Boolean := True;
   --  Set to False with switch -f of gnatclean and gprclean

   Display_Compilation_Progress : Boolean := False;
   --  Set True (-d switch) to display information on progress while compiling
   --  files. Internal flag to be used in conjunction with an IDE (e.g GPS).

   Follow_Links_For_Files : Boolean := False;
   --  Set to True (-eL) to process the project files in trusted mode. If
   --  Follow_Links is False, it is assumed that the project doesn't contain
   --  any file duplicated through symbolic links (although the latter are
   --  still valid if they point to a file which is outside of the project),
   --  and that no directory has a name which is a valid source name.

   Follow_Links_For_Dirs : Boolean := False;
   --  Set to True if directories can be links in this project, and therefore
   --  additional system calls must be performed to ensure that we always see
   --  the same full name for each directory.

   Force_Compilations : Boolean := False;
   --  Set to force recompilations even when the objects are up-to-date.

   Full_Path_Name_For_Brief_Errors : Boolean := False;
   --  When True, in Brief_Output mode, each error message line will start with
   --  the full path name of the source. When False, only the file name without
   --  directory information is used.

   GnatProve_Mode : Boolean := False;
   --  Enable GnatProve mode: the .ali files are copied to the lib dir even
   --  when only compilation is performed.

   Ignore_Predefined_Units : Boolean := False;
   --  Ignore predefined Ada units in gprname.
   --  Set by switch --ignore-predefined-units.

   Ignore_Duplicate_Files : Boolean := False;
   --  Ignore filenames with the same basename and only keep the first one.
   --  Set by switch --ignore-duplicate-files.

   Implicit_With : String_Access;
   --  Add the given project as a dependency on all loaded projects

   Keep_Going : Boolean := False;
   --  When True signals to ignore compilation errors and keep processing
   --  sources until there is no more work.

   Keep_Temporary_Files : Boolean := False;
   --  When True the temporary files are not deleted. Set by switches -dn or
   --  --keep-temp-files.

   Link_Only : Boolean := False;
   --  Set to True to skip compile and bind steps (except when Bind_Only is
   --  set to True).

   Maximum_Compilers : Positive := 1;
   --  Maximum number of processes that should be spawned to carry out
   --  compilations.

   Maximum_Binders : Positive := 1;
   --  Maximum number of processes that should be spawned to carry out
   --  bindings.

   Maximum_Linkers : Positive := 1;
   --  Maximum number of processes that should be spawned to carry out
   --  linkings.

   Minimal_Recompilation : Boolean := False;
   --  Set to True if minimal recompilation mode requested

   Checksum_Recompilation : Boolean := False;
   --  Set to True if checksum-based recompilation mode requested

   No_Backup : Boolean := False;
   --  Do not create backup copies of project files in gprname.
   --  Set by switch --no-backup.

   No_Main_Subprogram : Boolean := False;
   --  Set to True if compilation/binding of a program without main
   --  subprogram requested.

   No_Split_Units : Boolean := False;
   --  Set to True with switch --no-split-units. When True, unit sources, spec,
   --  body and subunits, must all be in the same project. This is checked
   --  after each compilation.

   One_Compilation_Per_Obj_Dir : Boolean := False;
   --  Set to True with switch --single-compile-per-obj-dir. When True, there
   --  cannot be simultaneous compilations with the object files in the same
   --  object directory, if project files are used.

   Quiet_Output : Boolean := False;
   --  Set to True if the tool should not have any output if there are no
   --  errors or warnings.

   Run_Path_Option : Boolean := True;
   --  Set to False when no run_path_option should be issued to the linker

   Setup_Projects : Boolean := False;
   --  Set to True to indicate that the Project Manager needs to creates
   --  non existing object, library and exec directories.

   type Origin_Of_Target is (Unknown, Default, Specified);

   Target_Origin : Origin_Of_Target := Unknown;
   --  Indicates the origin of attribute Target in project files

   Target_Value : String_Access := null;
   --  Indicates the value of attribute Target in project files

   Target_Value_Canonical : String_Access := null;
   --  Canonical value of specified target

   Unchecked_Shared_Lib_Imports : Boolean := False;
   --  Set to True when shared library projects are allowed to import projects
   --  that are not shared library projects. Set on by use of the switch
   --  --unchecked-shared-lib-imports.

   Upper_Half_Encoding : Boolean := False;
   --  Normally set False, indicating that upper half ISO 8859-1 characters are
   --  used in the normal way to represent themselves. If the wide character
   --  encoding method uses the upper bit for this encoding, then this flag is
   --  set True, and upper half characters in the source indicate the start of
   --  a wide character sequence. Set by -gnatW or -W switches.

   Use_Include_Path_File : Boolean := False;
   --  When True, create a source search path file, even when a mapping file
   --  is used.

   Verbose_Mode : Boolean := False;
   --  Set to True to get verbose mode (full error message text and location
   --  information sent to standard output, also header, copyright and summary)

   type Verbosity_Level_Type is (None, Low, Medium, High);
   pragma Ordered (Verbosity_Level_Type);
   Verbosity_Level : Verbosity_Level_Type := None;
   --  Modified by gnatmake or gprmake switches -v, -vl, -vm, -vh. Indicates
   --  the level of verbosity of informational messages:
   --
   --  In Low Verbosity, the reasons why a source is recompiled, the name
   --  of the executable and the reason it must be rebuilt is output.
   --
   --  In Medium Verbosity, additional lines are output for each ALI file
   --  that is checked.
   --
   --  In High Verbosity, additional lines are output when the ALI file
   --  is part of an Ada library, is read-only or is part of the runtime.

   No_Exit_Message : Boolean := False;
   --  Set with switch --no-exit-message. When True, if there are compilation
   --  failures, the builder does not issue an exit error message.

   type Warning_Mode_Type is (Suppress, Normal, Treat_As_Error);
   Warning_Mode : Warning_Mode_Type := Normal;
   --  Controls treatment of warning messages. If set to Suppress, warning
   --  messages are not generated at all. In Normal mode, they are generated
   --  but do not count as errors. In Treat_As_Error mode, warning messages are
   --  generated and are treated as errors. Note that Warning_Mode = Suppress
   --  causes pragma Warnings to be ignored (except for legality checks),
   --  unless we are in GNATprove_Mode, which requires pragma Warnings to
   --  be stored for the formal verification backend.

   Wide_Character_Encoding_Method : WC_Encoding_Method := WCEM_Brackets;
   --  Method used for encoding wide characters in the source program. See
   --  description of type in unit System.WCh_Con for a list of the methods
   --  that are currently supported. Note that brackets notation is always
   --  recognized in source programs regardless of the setting of this
   --  variable. The default setting causes only the brackets notation to be
   --  recognized. If this is the main unit, this setting also controls the
   --  output of the W=? parameter in the ALI file, which is used to provide
   --  the default for encoding [Wide_[Wide_]]Text_IO files. For the binder,
   --  the value set here overrides this main unit default.

   Wide_Character_Encoding_Method_Specified : Boolean := False;
   --  Set True if the value in Wide_Character_Encoding_Method was set as
   --  a result of an explicit -gnatW? or -W? switch. False otherwise.

end GPR.Opt;
