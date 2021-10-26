------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2004-2021, AdaCore                     --
--                                                                          --
-- This is  free  software;  you can redistribute it and/or modify it under --
-- terms of the  GNU  General Public License as published by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for more details.  You should have received  a copy of the  GNU  --
-- General Public License distributed with GNAT; see file  COPYING. If not, --
-- see <http://www.gnu.org/licenses/>.                                      --
--                                                                          --
------------------------------------------------------------------------------

--  The following package implements the facilities to compile, bind and/or
--  link a set of Ada and non Ada sources, specified in Project Files.

private with Ada.Containers.Hashed_Maps;
private with Ada.Containers.Indefinite_Vectors;
private with Ada.Containers.Vectors;

with GPR;       use GPR;
with GPR.Osint; use GPR.Osint;

private with GNAT.HTable;
private with GNAT.OS_Lib;

private with Gpr_Build_Util;
private with GPR.ALI;
private with GPR.Opt;
private with GPR.Util;

package Gprbuild is

   --  Everything is private so only accessible to child packages

private

   use Ada.Containers;
   use Gpr_Build_Util;
   use GNAT.OS_Lib;
   use GPR.Util;

   pragma Warnings (Off); -- Used by children
   use Stamps;
   use type ALI.ALI_Id, Opt.Verbosity_Level_Type, Opt.Warning_Mode_Type;
   pragma Warnings (On);

   Exit_Code : Osint.Exit_Code_Type := Osint.E_Success;
   --  Exit code for gprbuild

   Object_Suffix : constant String := Get_Target_Object_Suffix.all;
   --  The suffix of object files on this platform

   Dash_L : Name_Id;
   --  "-L", initialized in procedure Initialize

   Main_Project_Dir : String_Access;
   --  The absolute path of the project directory of the main project,
   --  initialized in procedure Initialize.

   Executable_Suffix : constant String_Access := Get_Executable_Suffix;
   --  The suffix of executables on this platforms

   Main_Index : Int := 0;

   Project_Tree : constant Project_Tree_Ref :=
                    new Project_Tree_Data (Is_Root_Tree => True);
   --  The project tree

   Copyright_Output : Boolean := False;
   Usage_Output     : Boolean := False;
   --  Flags to avoid multiple displays of Copyright notice and of Usage

   Usage_Needed : Boolean := False;
   --  Set by swith -h: usage will be displayed after all command line
   --  switches have been scanned.

   Display_Paths : Boolean := False;
   --  Set by switch --display-paths: config project path and user project path
   --  will be displayed after all command lines witches have been scanned.

   Output_File_Name           : String_Access := null;
   --  The name given after a switch -o

   Output_File_Name_Expected  : Boolean := False;
   --  True when last switch was -o

   Project_File_Name_Expected : Boolean := False;
   --  True when last switch was -P

   Search_Project_Dir_Expected : Boolean := False;
   --  True when last switch was -aP

   Object_Checked : Boolean := True;
   --  False when switch --no-object-check is used. When True, presence of
   --  the object file and its time stamp are checked to decide if a file needs
   --  to be compiled. Also set to False when switch --codepeer is used.

   Map_File : String_Access := null;
   --  Value of switch --create-map-file

   Indirect_Imports : Boolean := True;
   --  False when switch --no-indirect-imports is used. Sources are only
   --  allowed to import from the projects that are directly withed.

   Recursive : Boolean := False;

   Unique_Compile : Boolean := False;
   --  Set to True if -u or -U or a project file with no main is used

   Unique_Compile_All_Projects : Boolean := False;
   --  Set to True if -U is used

   Always_Compile : Boolean := False;
   --  Set to True when gprbuid is called with -f -u and at least one source
   --  on the command line.

   Builder_Switches_Lang : Name_Id := No_Name;
   --  Used to decide to what compiler the Builder'Default_Switches that
   --  are not recognized by gprbuild should be given.

   No_SAL_Binding : Boolean := False;
   --  Set to True with gprbuild switch --no-sal-binding

   All_Language_Builder_Compiling_Options : String_Vectors.Vector;
   --  Table to store the options for all compilers, that is those that
   --  follow the switch "-cargs" without any mention of language in the
   --  Builder switches.

   All_Language_Compiling_Options         : String_Vectors.Vector;
   --  Table to store the options for all compilers, that is those that
   --  follow the switch "-cargs" without any mention of language on the
   --  command line.

   Builder_Compiling_Options              : String_Vectors.Vector;
   --  Table to store the options for the compilers of the different
   --  languages, that is those after switch "-cargs:<lang>", in the Builder
   --  switches.

   Compiling_Options                      : String_Vectors.Vector;
   --  Table to store the options for the compilers of the different
   --  languages, that is those after switch "-cargs:<lang>", on the command
   --  line.

   Initial_Number_Of_Options : constant Natural := 10;

   type Option_Type (Name_Len : Natural) is record
      Name : String (1 .. Name_Len);
      --  Used to store the argument to be used when spawning a process

      Displayed : Boolean;
      --  Indicate if the argument should be displayed when procedure
      --  Display_Command is called.

      Simple_Name : Boolean;
      --  Indicate that the argument is a path name and that only the simple
      --  name should be displayed.
   end record;

   package Option_Vectors is new Ada.Containers.Indefinite_Vectors
     (Positive, Option_Type);

   subtype Options_Data is Option_Vectors.Vector;
   --  Keeps the options of a tool with a boolean for each that
   --  indicates if it should be displayed.

   function Options_List (Options : Options_Data) return String_Vectors.Vector;
   --  Extract all Switches from Option data and return them as a list

   Compilation_Options : Options_Data;
   --  The compilation options coming from package Compiler

   No_Comp_Option_Table : constant String_Vector_Access := null;

   Current_Comp_Option_Table : String_Vector_Access := No_Comp_Option_Table;

   No_Builder_Comp_Option_Table : constant String_Vector_Access := null;

   Cmd_Line_Adc_Files : Name_Id_Maps.Map;
   --  -gnatec command line option values

   package Compiling_Options_HTable is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => String_Vector_Access,
      No_Element => No_Comp_Option_Table,
      Key        => Name_Id,
      Hash       => GPR.Hash,
      Equal      => "=");
   --  A hash table to get the command line compilation option table from the
   --  language name.

   package Builder_Compiling_Options_HTable is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => String_Vector_Access,
      No_Element => No_Builder_Comp_Option_Table,
      Key        => Name_Id,
      Hash       => GPR.Hash,
      Equal      => "=");
   --  A hash table to get the builder compilation option table from the
   --  language name.

   All_Language_Binder_Options : String_Vectors.Vector;
   --  Table to store the options for all binders, that is those that
   --  follow the switch "-bargs" without any mention of language.

   Binder_Options : String_Vectors.Vector;
   --  Tables to store the options for the binders of the different
   --  languages, that is those after switch "-bargs:<lang>".

   type Bind_Option_Table_Ref is access String_Vectors.Vector;
   No_Bind_Option_Table : constant Bind_Option_Table_Ref := null;

   Current_Bind_Option_Table : Bind_Option_Table_Ref := No_Bind_Option_Table;

   package Binder_Options_HTable is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => Bind_Option_Table_Ref,
      No_Element => No_Bind_Option_Table,
      Key        => Name_Id,
      Hash       => GPR.Hash,
      Equal      => "=");
   --  A hash table to get the binder option table from the language name

   Command_Line_Linker_Options : String_Vectors.Vector;
   --  Table to store the linking options

   Command_Line_Gprconfig_Options : String_Vectors.Vector;
   --  Table to store the gprconfig options

   Project_Of_Current_Object_Directory : Project_Id := No_Project;
   --  The object directory of the project for the last binding. Avoid
   --  calling Change_Dir if the current working directory is already this
   --  directory.

   --  Archive builder name, path and options

   Archive_Builder_Name        : String_Access := null;
   Archive_Builder_Path        : String_Access := null;
   Archive_Builder_Opts        : Options_Data;
   Archive_Builder_Append_Opts : Options_Data;

   --  Archive indexer name, path and options

   Archive_Indexer_Name : String_Access := null;
   Archive_Indexer_Path : String_Access := null;
   Archive_Indexer_Opts : Options_Data;

   --  Object lister name and options

   Object_Lister_Name    : String_Access := null;
   Object_Lister_Path    : String_Access := null;
   Object_Lister_Opts    : Options_Data;
   Object_Lister_Matcher : String_Access;
   Library_Symbol_File   : String_Access;

   --  Export file

   Export_File_Switch    : String_Access := null;
   Export_File_Format    : GPR.Export_File_Format := GPR.None;

   --  Libraries

   type Library_Project is record
      Proj          : Project_Id;
      Is_Aggregated : Boolean;
   end record;

   package Library_Proj_Vectors is new Ada.Containers.Vectors
     (Positive, Library_Project);

   Library_Projs     : Library_Proj_Vectors.Vector;
   --  Library projects imported directly or indirectly

   Non_Library_Projs : Project_Vectors.Vector;
   --  Non library projects imported directly or indirectly

   procedure Add_Option
     (Value       : String;
      To          : in out Options_Data;
      Display     : Boolean;
      Simple_Name : Boolean := False);
   procedure Add_Option
     (Value       : Name_Id;
      To          : in out Options_Data;
      Display     : Boolean;
      Simple_Name : Boolean := False);
   procedure Add_Options
     (Value         : String_List_Id;
      To            : in out Options_Data;
      Display_All   : Boolean;
      Display_First : Boolean;
      Simple_Name   : Boolean := False);
   --  Add one or several options to a list of options. Increase the size
   --  of the list, if necessary.

   function Get_Option (Option : Name_Id) return String;
   --  Get a string access corresponding to Option. Either find the string
   --  access in the All_Options cache, or create a new entry in All_Options.

   procedure Test_If_Relative_Path
     (Switch           : in out String_Access;
      Parent           : String;
      Including_Switch : Name_Id);
   --  Changes relative paths to absolute paths. When Switch is not a
   --  switch (it does not start with '-'), then if it is a relative path
   --  and Parent/Switch is a regular file, then Switch is modified to
   --  be Parent/Switch. If Switch is a switch (it starts with '-'),
   --  Including_Switch is not null, Switch starts with Including_Switch
   --  and the remainder is a relative path, then if Parent/remainder is
   --  an existing directory, then Switch is modified to have an absolute
   --  path following Including_Switch.
   --  Whenever Switch is modified, its previous value is deallocated.

   procedure Add_Option_Internal
     (Value       : String;
      To          : in out Options_Data;
      Display     : Boolean;
      Simple_Name : Boolean := False) renames Add_Option;
   --  Add an option in a specific list of options

   procedure Add_Option_Internal_Codepeer
     (Value       : String;
      To          : in out Options_Data;
      Display     : Boolean;
      Simple_Name : Boolean := False);
   --  Similar to procedure Add_Option_Internal, except that in CodePeer
   --  mode, options -mxxx are not added.

   procedure Process_Imported_Libraries
     (For_Project        : Project_Id;
      There_Are_SALs     : out Boolean;
      And_Project_Itself : Boolean := False);
   --  Get the imported library project ids in table Library_Projs

   procedure Process_Imported_Non_Libraries (For_Project : Project_Id);
   --  Get the imported non library project ids in table Non_Library_Projs

   function Create_Path_From_Dirs return String_Access;
   --  Concatenate all directories in the Directories table into a path.
   --  Caller is responsible for freeing the result

   procedure Check_Archive_Builder;
   --  Check if the archive builder (ar) is there

   procedure Check_Object_Lister;
   --  Check object lister (nm) is there

   procedure Check_Export_File;
   --  Check for export file option and format

   procedure Check_Library_Symbol_File;
   --  Check for the library symbol file

   function Archive_Suffix (For_Project : Project_Id) return String;
   --  Return the archive suffix for the project, if defined, otherwise
   --  return ".a".

   procedure Change_To_Object_Directory
     (Project          : Project_Id;
      Must_Be_Writable : Boolean := False);
   --  Change to the object directory of project Project, if this is not
   --  already the current working directory. If Must_Be_Writable is True and
   --  the object directory is not writable, fail with an error message.

   Bad_Processes : Main_Info_Vectors.Vector;
   --  Info for all the mains where binding fails

   function String_Vector_To_String (SV : String_Vectors.Vector) return String;
   --  Use Name_Buffer to return a whitespace-separated string
   --  from a string vector.

   Outstanding_Processes : Natural := 0;
   --  The number of bind jobs currently spawned

   Stop_Spawning : Boolean := False;
   --  True when one bind process failed and switch -k was not used

   procedure Record_Failure (Main : Main_Info);
   --  Add Main to table Bad_Processes and set Stop_Binding to True if switch
   --  -k is not used.

   type Process_Kind is (None, Binding, Linking);

   type Process_Data is record
      Kind : Process_Kind := None;
      Main : Main_Info    := No_Main_Info;
   end record;

   No_Process_Data : constant Process_Data := (None, No_Main_Info);

   function Hash (Pid : Process_Id) return Ada.Containers.Hash_Type;
   --  Used for Process_Htable below

   package Process_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Process_Id,
      Element_Type    => Process_Data,
      Hash            => Hash,
      Equivalent_Keys => "=");

   Processes : Process_Maps.Map;
   --  Hash table to keep data for all spawned jobs

   procedure Add_Process (Process : Process_Id; Data : Process_Data);
   --  Add process in the Process_Htable

   procedure Await_Process (Data : out Process_Data; OK : out Boolean);
   --  Wait for the end of a bind job

   procedure Display_Processes (Name : String);
   --  When -jnn, -v and -vP2 are used, display the number of currently spawned
   --  processes.

   procedure Sigint_Intercepted;
   pragma Convention (C, Sigint_Intercepted);
   --  Called when the program is interrupted by Ctrl-C to delete the
   --  temporary mapping files and configuration pragmas files.

   function No_Link_Target (Name : String) return Boolean is
     (Name in "c" | "ccg" | "jvm");
   --  Target with this name does not allow linking

end Gprbuild;
