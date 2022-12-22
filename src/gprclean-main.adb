------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2011-2020, AdaCore                     --
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

--  This package contains the implementation of gprclean.
--  See gprclean.adb

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;   use Ada.Exceptions;
with Ada.Text_IO;      use Ada.Text_IO;

with GNAT.Case_Util;            use GNAT.Case_Util;
with GNAT.Command_Line;         use GNAT.Command_Line;
with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.OS_Lib;               use GNAT.OS_Lib;

with Gpr_Build_Util;             use Gpr_Build_Util;
with GPR;                        use GPR;
with GPR.Compilation.Slave;      use GPR.Compilation;
with GPR.Conf;                   use GPR.Conf;
with GPR.Env;
with GPR.Err;
with GPR.Ext;
with GPR.Names;                  use GPR.Names;
with GPR.Opt;                    use GPR.Opt;
with GPR.Osint;
with GPR.Proc;                   use GPR.Proc;
with GPR.Snames;
with GPR.Tree;                   use GPR.Tree;
with GPR.Util.Aux;               use GPR.Util;

procedure Gprclean.Main is

   Project_File_Name_Expected : Boolean := False;

   Search_Project_Dir_Expected : Boolean := False;

   User_Project_Node : Project_Node_Id;

   In_Package_Clean : Boolean := False;
   --  True when processing switches from package Clean of the main project

   procedure Usage;
   --  Display the usage.
   --  If called several times, the usage is displayed only the first time.

   procedure Parse_Cmd_Line;
   --  Parse the command line

   procedure Process_Switch (Switch : String);
   --  Process a switch

   procedure Compute_Clean_Switches;
   --  Get the switches from package Clean of main project, if any

   procedure Display_Copyright;
   --  Display the Copyright notice. If called several times, display the
   --  Copyright notice only the first time.

   procedure Initialize;
   --  Call the necessary package initializations

   procedure Check_Version_And_Help is new Check_Version_And_Help_G (Usage);

   -----------------------
   -- Display_Copyright --
   -----------------------

   procedure Display_Copyright is
   begin
      if not Copyright_Displayed then
         Copyright_Displayed := True;
         Display_Version ("GPRCLEAN", "2006");
      end if;
   end Display_Copyright;

   ----------------------------
   -- Compute_Clean_Switches --
   ----------------------------

   procedure Compute_Clean_Switches is
      Clean_Package  : constant Package_Id :=
        Value_Of
          (Snames.Name_Clean,
           Main_Project.Decl.Packages,
           Project_Tree.Shared);

      Switches : Variable_Value;
      List : String_List_Id;
      Elem : String_Element;
   begin
      if Clean_Package /= No_Package then
         In_Package_Clean := True;
         Switches := Value_Of
           (Variable_Name => Snames.Name_Switches,
            In_Variables  => Project_Tree.Shared.Packages.Table
              (Clean_Package).Decl.Attributes,
            Shared        => Project_Tree.Shared);

         List := Switches.Values;
         while List /= Nil_String loop
            Elem := Project_Tree.Shared.String_Elements.Table (List);
            Get_Name_String (Elem.Value);
            Process_Switch (Switch => Name_Buffer (1 .. Name_Len));
            List := Elem.Next;
         end loop;
      end if;
   end Compute_Clean_Switches;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      if not Initialized then
         Initialized := True;

         --  Initialize some packages

         Snames.Initialize;

         Set_Program_Name ("gprclean");

         GPR.Tree.Initialize (Root_Environment, Gprclean_Flags);
         GPR.Tree.Initialize (Project_Node_Tree);
      end if;

      --  Reset global variables

      Do_Nothing := False;
      File_Deleted := False;
      Copyright_Displayed := False;
      Usage_Displayed := False;
      Free (Project_File_Name);
      Main_Project := GPR.No_Project;
      All_Projects := False;
      Mains.Delete;
   end Initialize;

   --------------------
   -- Parse_Cmd_Line --
   --------------------

   procedure Parse_Cmd_Line is
      Last  : constant Natural := Argument_Count;
      Index : Positive := 1;

   begin
      --  First deal with --version and --help

      Check_Version_And_Help ("GPRCLEAN", "2006");

      --  Now deal with the other options

      while Index <= Last loop
         declare
            Arg : constant String := Argument (Index);

         begin
            if Db_Directory_Expected then
               Db_Directory_Expected := False;
               Knowledge.Parse_Knowledge_Base (Project_Tree, Arg);

               Set_Name_Buffer (Arg);
               Add_Db_Switch_Arg (Name_Find);

            elsif Arg'Length /= 0 then
               if Arg (1) = '-' then
                  Process_Switch (Arg);

                  if Project_File_Name_Expected then
                     if Index = Last then
                        Fail_Program
                          (Project_Tree,
                           "no project specified after -P");
                     end if;

                     Index := Index + 1;
                     Project_File_Name := new String'(Argument (Index));
                     Project_File_Name_Expected := False;

                  elsif Search_Project_Dir_Expected then
                     if Index = Last then
                        Fail_Program
                          (Project_Tree, "directory name missing after -aP");
                     end if;

                     Index := Index + 1;
                     GPR.Env.Add_Directories
                       (Root_Environment.Project_Path, Argument (Index));
                     Search_Project_Dir_Expected := False;
                  end if;

               else
                  --  The file name of a main or a project file

                  declare
                     File_Name : String := Arg;

                  begin
                     Osint.Canonical_Case_File_Name (File_Name);

                     if File_Name'Length > Project_File_Extension'Length
                       and then
                        File_Name
                          (File_Name'Last - Project_File_Extension'Length + 1
                           .. File_Name'Last) = Project_File_Extension
                     then
                        if No_Project_File then
                           Fail_Program
                             (Project_Tree,
                              "cannot specify --no-project" &
                              " with a project file");

                        elsif Project_File_Name /= null then
                           Fail_Program
                             (Project_Tree,
                              "cannot have several project files specified");

                        else
                           Project_File_Name := new String'(File_Name);
                        end if;

                     else
                        --  Not a project file, then it is a main

                        Mains.Add_Main (Arg);
                     end if;
                  end;
               end if;
            end if;
         end;

         Index := Index + 1;
      end loop;
   end Parse_Cmd_Line;

   --------------------
   -- Process_Switch --
   --------------------

   procedure Process_Switch (Switch : String) is
      pragma Assert (Switch'First = 1);

      procedure Bad_Switch;
      --  Signal bad switch and fail

      ----------------
      -- Bad_Switch --
      ----------------

      procedure Bad_Switch is
      begin
         if In_Package_Clean then
            Fail_Program
              (Project_Tree,
               "invalid switch """ & Switch & """ in package Clean");

         else
            Fail_Program (Project_Tree, "invalid switch """ & Switch & '"');
         end if;
      end Bad_Switch;

   begin
      if Switch'Length = 1 then
         Bad_Switch;
      end if;

      case Switch (2) is
         when '-' =>
            if In_Package_Clean then
               Bad_Switch;

            elsif Switch = "--db-" then
               Load_Standard_Base := False;

            elsif Switch = "--db" then
               Db_Directory_Expected := True;

            elsif Switch = No_Project_Option then
               No_Project_File := True;

               if Project_File_Name /= null then
                  Fail_Program
                    (Project_Tree,
                     "cannot specify --no-project with a project file");
               end if;

            elsif Switch'Length > Config_Project_Option'Length
              and then Switch (1 .. Config_Project_Option'Length) =
              Config_Project_Option
            then
               if Config_Project_File_Name /= null
                 and then
                   (Autoconf_Specified
                    or else Config_Project_File_Name.all /=
                      Switch (Config_Project_Option'Length + 1
                           .. Switch'Last))
               then
                  Fail_Program
                    (Project_Tree,
                     "several configuration switches cannot "
                     & "be specified");

               else

                  Autoconfiguration := False;
                  Config_Project_File_Name :=
                    new String'
                      (Switch (Config_Project_Option'Length + 1
                       .. Switch'Last));
               end if;

            elsif Switch'Length >=  Distributed_Option'Length
              and then
                Switch (1 .. Distributed_Option'Length)
              = Distributed_Option
            then
               Distributed_Mode := True;

               declare
                  Hosts : constant String :=
                            Aux.Get_Slaves_Hosts (Project_Tree, Switch);
               begin
                  if Hosts = "" then
                     Fail_Program
                       (Project_Tree,
                        "missing hosts for distributed"
                        & " mode compilation");

                  else
                     GPR.Compilation.Slave.Record_Slaves (Hosts);
                  end if;
               end;

            elsif Switch'Length >= Slave_Env_Option'Length
              and then
                Switch (1 .. Slave_Env_Option'Length)
              = Slave_Env_Option
            then
               if Switch = Slave_Env_Option then
                  --  Just --slave-env, it is up to gprbuild to
                  --  build a sensible slave environment value.
                  Slave_Env_Auto := True;
               else
                  Slave_Env := new String'
                    (Switch
                       (Slave_Env_Option'Length + 2 .. Switch'Last));
               end if;

            elsif Switch'Length > Autoconf_Project_Option'Length
              and then
                Switch (1 .. Autoconf_Project_Option'Length) =
              Autoconf_Project_Option
            then
               if Config_Project_File_Name /= null
                 and then
                   (not Autoconf_Specified
                    or else
                    Config_Project_File_Name.all /=
                      Switch (Autoconf_Project_Option'Length + 1
                           .. Switch'Last))
               then
                  Fail_Program
                    (Project_Tree,
                     "several configuration switches cannot "
                     & "be specified");

               else
                  Config_Project_File_Name :=
                    new String'
                      (Switch (Autoconf_Project_Option'Length + 1
                       .. Switch'Last));
                  Autoconf_Specified := True;
               end if;

            elsif Switch'Length > Target_Project_Option'Length
              and then
                Switch (1 .. Target_Project_Option'Length) =
              Target_Project_Option
            then
               if Target_Name /= null then
                  if Target_Name.all /=
                    Switch (Target_Project_Option'Length + 1
                         .. Switch'Last)
                  then
                     Fail_Program
                       (Project_Tree,
                        "several target switches "
                        & "cannot be specified");
                  end if;

               else
                  Target_Name :=
                    new String'
                      (Switch (Target_Project_Option'Length + 1
                       .. Switch'Last));
               end if;

            elsif Switch'Length > RTS_Option'Length
              and then Switch (1 .. RTS_Option'Length) = RTS_Option
            then
               declare
                  Set : constant Boolean :=
                    Runtime_Name_Set_For (Snames.Name_Ada);
                  Old : constant String :=
                    Runtime_Name_For (Snames.Name_Ada);
                  RTS : constant String :=
                    Switch (RTS_Option'Length + 1 .. Switch'Last);

               begin
                  if Set and then Old /= RTS then
                     Fail_Program
                       (Project_Tree,
                        "several different run-times " &
                          "cannot be specified");
                  end if;

                  Set_Runtime_For (Snames.Name_Ada, RTS);
                  Set_Default_Runtime_For (Snames.Name_Ada, RTS);
               end;

            elsif Switch'Length > RTS_Language_Option'Length
              and then Switch (1 .. RTS_Language_Option'Length) =
              RTS_Language_Option
            then
               declare
                  Language_Name : Name_Id := No_Name;
                  RTS_Start : Natural := Switch'Last + 1;

               begin
                  for J in RTS_Language_Option'Length + 2 ..
                    Switch'Last
                  loop
                     if Switch (J) = '=' then
                        Set_Name_Buffer
                          (Switch
                             (RTS_Language_Option'Length + 1 ..
                                  J - 1));
                        To_Lower (Name_Buffer (1 .. Name_Len));
                        Language_Name := Name_Find;
                        RTS_Start := J + 1;
                        exit;
                     end if;
                  end loop;

                  if Language_Name = No_Name then
                     Bad_Switch;

                  else

                     declare
                        RTS : constant String :=
                          Switch (RTS_Start .. Switch'Last);
                        Set : constant Boolean :=
                          Runtime_Name_Set_For (Language_Name);
                        Old : constant String :=
                          Runtime_Name_For (Language_Name);

                     begin
                        if Set and then Old /= RTS then
                           Fail_Program
                             (Project_Tree,
                              "several different run-times cannot" &
                                " be specified for the same language");

                        else
                           Set_Runtime_For (Language_Name, RTS);
                           Set_Default_Runtime_For (Language_Name, RTS);
                        end if;
                     end;
                  end if;
               end;

            elsif Switch'Length > Implicit_With_Option'Length
              and then
                Switch (Implicit_With_Option'Range) = Implicit_With_Option
            then
               if Implicit_With /= null then
                  Fail_Program
                    (Project_Tree,
                     "several " & Implicit_With_Option
                     & " options cannot be specified");
               end if;

               Implicit_With := new String'
                 (Ensure_Suffix
                    (Switch (Implicit_With_Option'Last + 1 .. Switch'Last),
                     Project_File_Extension));

            elsif Switch'Length > Subdirs_Option'Length
              and then
                Switch (1 .. Subdirs_Option'Length) = Subdirs_Option
            then
               Subdirs :=
                 new String'
                   (Switch (Subdirs_Option'Length + 1 .. Switch'Last));

            elsif Switch'Length > Src_Subdirs_Option'Length
              and then
                Switch (1 .. Src_Subdirs_Option'Length) = Src_Subdirs_Option
            then
               Src_Subdirs :=
                 new String'
                   (Switch (Src_Subdirs_Option'Length + 1 .. Switch'Last));

            elsif Switch'Length >= Relocate_Build_Tree_Option'Length
              and then Switch (1 .. Relocate_Build_Tree_Option'Length)
              = Relocate_Build_Tree_Option
            then
               if Switch'Length
                 = Relocate_Build_Tree_Option'Length
               then
                  Build_Tree_Dir := new String'(Get_Current_Dir);

               else
                  declare
                     Dir : constant String := Ensure_Directory
                       (Switch (Relocate_Build_Tree_Option'Length + 2
                        .. Switch'Last));
                  begin
                     Build_Tree_Dir :=
                       (if Is_Absolute_Path (Dir) then new String'(Dir)
                        else new String'(Get_Current_Dir & Dir));
                  end;
               end if;

            elsif Switch'Length >= Root_Dir_Option'Length
              and then Switch (1 .. Root_Dir_Option'Length)
              = Root_Dir_Option
            then
               Root_Dir :=
                 new String'
                   (Normalize_Pathname
                      (Switch
                         (Root_Dir_Option'Length + 2 .. Switch'Last),
                       Get_Current_Dir,
                       Resolve_Links => Opt.Follow_Links_For_Dirs)
                    & Dir_Separator);

            elsif
              Switch = Gpr_Build_Util.Unchecked_Shared_Lib_Imports
            then
               Opt.Unchecked_Shared_Lib_Imports := True;

            else
               Bad_Switch;
            end if;

         when 'a' =>
            if In_Package_Clean
              or else Switch'Length < 3
              or else Switch (3) /= 'P'
            then
               Bad_Switch;
            end if;

            if Switch'Length > 3 then
               GPR.Env.Add_Directories
                 (Root_Environment.Project_Path,
                  Switch (4 .. Switch'Last));
            else
               Search_Project_Dir_Expected := True;
            end if;

         when 'c'    =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            Compile_Only := True;

         when 'e' =>
            if Switch = "-eL" then
               Follow_Links_For_Files := True;
               Follow_Links_For_Dirs  := True;

            else
               Bad_Switch;
            end if;

         when 'f' =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            Force_Deletions := True;
            Opt.Directories_Must_Exist_In_Projects := False;

         when 'F' =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            Full_Path_Name_For_Brief_Errors := True;

         when 'h' =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            Display_Copyright;
            Usage;

         when 'n' =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            Do_Nothing := True;

         when 'p' =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            Remove_Empty_Dir := True;
            Opt.Directories_Must_Exist_In_Projects := False;

         when 'P' =>
            if In_Package_Clean then
               Bad_Switch;
            end if;

            if No_Project_File then
                  Fail_Program
                    (Project_Tree,
                     "cannot specify --no-project with a project file");

            elsif Project_File_Name /= null then
               Fail_Program (Project_Tree, "multiple -P switches");
            end if;

            if Switch'Length > 2 then
               declare
                  Prj : constant String := Switch (3 .. Switch'Last);
               begin
                  Project_File_Name :=
                    (if Prj'Length > 1 and then Prj (Prj'First) = '=' then
                       new String'(Prj (Prj'First + 1 .. Prj'Last))
                     else new String'(Prj));
               end;

            else
               Project_File_Name_Expected := True;
            end if;

         when 'q' =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            if not In_Package_Clean or else not Verbose_Mode then
               Quiet_Output := True;
            end if;

         when 'r' =>
            if Switch'Length /= 2 then
               Bad_Switch;
            end if;

            All_Projects := True;

         when 'v' =>
            if Switch = "-v" then
               if not In_Package_Clean or else not Quiet_Output then
                  Verbose_Mode    := True;
                  Verbosity_Level := Opt.High;
               end if;

            elsif In_Package_Clean then
               Bad_Switch;

            elsif Switch = "-vP0" then
               Current_Verbosity := GPR.Default;

            elsif Switch = "-vP1" then
               Current_Verbosity := GPR.Medium;

            elsif Switch = "-vP2" then
               Current_Verbosity := GPR.High;

            else
               Bad_Switch;
            end if;

         when 'X' =>
            if In_Package_Clean then
               Bad_Switch;
            end if;

            if Switch'Length = 2 then
               Bad_Switch;
            end if;

            declare
               Ext_Asgn : constant String := Switch (3 .. Switch'Last);
               Start    : Positive := Ext_Asgn'First;
               Stop     : Natural  := Ext_Asgn'Last;
               OK       : Boolean  := True;

            begin
               if Ext_Asgn (Start) = '"' then
                  if Ext_Asgn (Stop) = '"' then
                     Start := Start + 1;
                     Stop  := Stop - 1;
                  else
                     OK := False;
                  end if;
               end if;

               if not OK
                 or else not GPR.Ext.Check
                   (Root_Environment.External,
                    Declaration => Ext_Asgn (Start .. Stop))
               then
                  Fail_Program
                    (Project_Tree,
                     "illegal external assignment '"
                     & Ext_Asgn & ''');
               end if;
            end;

         when others =>
            Bad_Switch;
      end case;
   end Process_Switch;

   -----------
   -- Usage --
   -----------

   procedure Usage is
   begin
      if not Usage_Displayed then
         Usage_Displayed := True;

         Put_Line ("Usage: gprclean [switches] -P<project> {name}");

         New_Line;

         Put_Line ("  {name} is zero or more file names");
         New_Line;

         Display_Usage_Version_And_Help;

         --  Line for --no-project

         Put_Line ("  --no-project");
         Put_Line ("           Do not use project file");

         Put_Line ("  --distributed=slave1[,slave2]");
         Put_Line ("           Activate the remote clean-up");

         Put_Line ("  --slave-env[=name]");
         Put_Line ("           Use a specific slave's environment");

         Put_Line ("  --config=file.cgpr");
         Put_Line ("           Specify the configuration project file name");

         Put_Line ("  --autoconf=file.cgpr");
         Put_Line
           ("           Specify/create the main config project file name");

         Put_Line ("  --target=targetname");
         Put_Line ("           Specify a target for cross platforms");

         Put_Line ("  --db dir Parse dir as an additional knowledge base");

         Put_Line ("  --db-    Do not load the standard knowledge base");

         Put_Line ("  --RTS=<runtime>");
         Put_Line ("           Use runtime <runtime> for language Ada");
         Put_Line ("  --RTS:<lang>=<runtime>");
         Put_Line ("           Use runtime <runtime> for language <lang>");

         Put_Line ("  --relocate-build-tree[=dir]");
         Put_Line ("           Root obj/lib/exec dirs are current-directory" &
                    " or dir");
         Put_Line ("  --root-dir=dir");
         Put_Line ("           Root directory of obj/lib/exec to relocate");

         Put_Line ("  --src-subdirs=dir");
         Put_Line ("           Prepend <obj>/dir to the list of source dirs" &
                   " for each project");
         Put_Line ("  --subdirs=dir");
         Put_Line ("           Use dir as suffix to obj/lib/exec directories");
         Put_Line ("  " & Gpr_Build_Util.Unchecked_Shared_Lib_Imports);
         Put_Line ("           Shared lib projects may import any project");
         New_Line;

         Put_Line ("  -aP dir  Add directory dir to project search path");
         Put_Line ("  -c       Only delete compiler generated files");
         Put_Line ("  -eL      Follow symbolic links when processing "
                   & "project files");
         Put_Line ("  -f       Force deletions of unwritable files");
         Put_Line ("  -F       Full project path name "
                   & "in brief error messages");
         Put_Line ("  -h       Display this message");
         Put_Line ("  -n       Nothing to do: only list files to delete");
         Put_Line ("  -p       Remove empty build directories");
         Put_Line ("  -P<proj> Use Project File <proj>");
         Put_Line ("  -q       Be quiet/terse");
         Put_Line ("  -r       Clean all projects recursively");
         Put_Line ("  -v       Verbose mode");
         Put_Line ("  -vPx     Specify verbosity when parsing Project Files");
         Put_Line ("  -Xnm=val Specify an external reference "
                   & "for Project Files");
         New_Line;
      end if;
   end Usage;

begin
   --  Do the necessary initializations

   Initialize;

   --  Add the external variable GPR_TOOL (default value "gprbuild")

   Add_Gpr_Tool_External;

   --  Parse the command line, getting the switches and the executable names

   In_Package_Clean := False;
   Parse_Cmd_Line;

   GPR.Env.Initialize_Default_Project_Path
     (Root_Environment.Project_Path, Target_Name => "-");

   if Load_Standard_Base then
      Knowledge.Parse_Knowledge_Base (Project_Tree);
   end if;

   --  If no project file was specified, look first for a default

   if Project_File_Name = null then
      Look_For_Default_Project;
   end if;

   --  Check that a project file was specified and get the configuration

   if Project_File_Name = null then
      Try_Help;
      Fail_Program
        (Project_Tree,
         "no project file specified and no default project file");
   end if;

   --  Check consistency of out-of-tree build options

   if Root_Dir /= null and then Build_Tree_Dir = null then
      Fail_Program
        (Project_Tree,
         "cannot use --root-dir without --relocate-build-tree option");
   end if;

   --  Set default Root_Dir

   if Build_Tree_Dir /= null and then Root_Dir = null then
      Root_Dir := new String'
        (Ada.Directories.Containing_Directory
           (Normalize_Pathname
              (Project_File_Name.all,
               Resolve_Links => Opt.Follow_Links_For_Files))
         & Dir_Separator);
   end if;

   if Verbose_Mode then
      Display_Copyright;
   end if;

   if Opt.Verbose_Mode then
      New_Line;
      Put ("Parsing Project File """);
      Put (Project_File_Name.all);
      Put_Line (""".");
      New_Line;
   end if;

   --  Check command line arguments. These will be overridden when looking
   --  for the configuration file

   if Target_Name = null then
      Target_Name := new String'("");
   end if;

   if Config_Project_File_Name = null then
      Config_Project_File_Name := new String'("");
   end if;

   begin
      Main_Project := No_Project;
      Parse_Project_And_Apply_Config
        (Main_Project               => Main_Project,
         User_Project_Node          => User_Project_Node,
         Config_File_Name           => Config_Project_File_Name.all,
         Autoconf_Specified         => Autoconf_Specified,
         Project_File_Name          => Project_File_Name.all,
         Project_Tree               => Project_Tree,
         Project_Node_Tree          => Project_Node_Tree,
         Packages_To_Check          => Packages_To_Check,
         Env                        => Root_Environment,
         Allow_Automatic_Generation => Autoconfiguration,
         Automatically_Generated    => Delete_Autoconf_File,
         Config_File_Path           => Configuration_Project_Path,
         Target_Name                => Target_Name.all,
         Normalized_Hostname        => Knowledge.Normalized_Hostname,
         Implicit_Project           => No_Project_File_Found);

      --  Print warnings that might have occurred while parsing the project
      GPR.Err.Finalize;

      --  But avoid duplicate warnings later on
      GPR.Err.Initialize;

   exception
      when E : GPR.Conf.Invalid_Config =>
         Fail_Program (Project_Tree, Exception_Message (E));
   end;

   if Main_Project = No_Project then
      --  Don't flush messages in case of parsing error. This has already
      --  been taken care when parsing the tree. Otherwise, it results in
      --  the same message being displayed twice.

      Fail_Program
        (Project_Tree,
         """" & Project_File_Name.all & """ processing failed",
         Flush_Messages => Present (User_Project_Node));
   end if;

   --  Get the switches from package Clean of main project, if any

   Compute_Clean_Switches;

   --  Even if the config project file has not been automatically
   --  generated, gprclean will delete it if it was specified using
   --  --autoconf=.

   Delete_Autoconf_File := Delete_Autoconf_File or Autoconf_Specified;

   if Configuration_Project_Path /= null then
      Free (Config_Project_File_Name);
      Config_Project_File_Name := new String'
        (Base_Name (Configuration_Project_Path.all));
   end if;

   if Opt.Verbose_Mode then
      New_Line;
      Put ("Parsing of Project File """);
      Put (Project_File_Name.all);
      Put (""" is finished.");
      New_Line;
   end if;

   if Main_Project.Qualifier /= Aggregate_Library then
      Mains.Fill_From_Project (Main_Project, Project_Tree);
      Mains.Complete_Mains
        (Root_Environment.Flags, Main_Project, Project_Tree);
   end if;

   if Verbose_Mode then
      New_Line;
   end if;

   Processed_Projects.Clear;

   if Slave_Env = null and then Distributed_Mode then
      Slave_Env :=
        new String'(Aux.Compute_Slave_Env (Project_Tree, Slave_Env_Auto));

      if Slave_Env_Auto and not Opt.Quiet_Output then
         Put_Line ("slave environment is " & Slave_Env.all);
      end if;
   end if;

   --  Clean-up local build

   declare
      procedure Do_Clean (Prj : Project_Id; Tree : Project_Tree_Ref);
      --  Update sources info and cleanup project tree

      --------------
      -- Do_Clean --
      --------------

      procedure Do_Clean (Prj : Project_Id; Tree : Project_Tree_Ref) is
         Iter : Source_Iterator :=
                  For_Each_Source
                    (Tree, (if All_Projects then No_Project else Prj));
      begin
         --  Update info on all sources in Tree

         while GPR.Element (Iter) /= No_Source loop
            Initialize_Source_Record (GPR.Element (Iter));
            Next (Iter);
         end loop;

         --  For the main project and all aggregated projects, remove the
         --  binder and linker generated files.

         Clean_Project
           (Prj, Tree, Main => True, Remove_Executables => not Compile_Only);

         --  Clean-up remote slaves

         if Distributed_Mode then
            Slave.Clean_Up_Remote_Slaves (Tree, Prj);
         end if;
      end Do_Clean;

      procedure For_All is new For_Project_And_Aggregated (Do_Clean);

   begin
      --  For an aggregate project, we always cleanup all aggregated
      --  projects, whether "-r" was specified or not. But for those
      --  projects, we might not clean their imported projects.
      For_All (Main_Project, Project_Tree);
   end;

   if Delete_Autoconf_File and then not Do_Nothing then
      Delete_Temporary_File
        (Project_Tree.Shared, Configuration_Project_Path.all);
      Delete_All_Temp_Files (Project_Tree.Shared);
   end if;

   --  Warn if auto-configuration returns a failure status

   if Problem_During_Auto_Configuration then
      New_Line;
      Put_Line
        ("Cleaning may be incomplete, " &
         "as there were problems during auto-configuration");
   end if;

   --  In verbose mode, if Delete has not been called, indicate that
   --  no file needs to be deleted.

   if Verbose_Mode and (not File_Deleted) then
      New_Line;

      Put_Line
        ((if Do_Nothing then "No file needs to be deleted"
          else "No file has been deleted"));
   end if;
end Gprclean.Main;
