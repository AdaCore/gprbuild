------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2011-2023, AdaCore                     --
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

with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Exceptions;                         use Ada.Exceptions;
with Ada.Strings.Fixed;                      use Ada, Ada.Strings.Fixed;
with Ada.Strings.Unbounded;                  use Ada.Strings.Unbounded;
with Ada.Text_IO;                            use Ada.Text_IO;

with GNAT.Directory_Operations; use GNAT, GNAT.Directory_Operations;
with GNAT.Dynamic_HTables;
with GNAT.OS_Lib;               use GNAT.OS_Lib;

with Gpr_Build_Util;               use Gpr_Build_Util;
with GPR.Compilation;              use GPR.Compilation;

with GPR.Compilation.Process;      use GPR.Compilation.Process;
with GPR.Compilation.Slave;
with GPR.Debug;
with GPR.Env;
with GPR.Jobserver;                use GPR.Jobserver;
with GPR.Names;                    use GPR.Names;
with GPR.Opt;                      use GPR.Opt;
with GPR.Snames;                   use GPR.Snames;
with GPR.Tempdir;
with GPR.Util;                     use GPR.Util;

package body Gprbuild.Compile is

   procedure Add_Compilation_Switches (Source : Source_Id);
   --  Add to the compilation option, the switches declared in
   --  Compiler'Switches(<source file name>), if it is defined, otherwise in
   --  Compiler'Default_Switches (<language name>), if it is defined.

   procedure Await_Compile
     (Source : out Queue.Source_Info;
      OK     : out Boolean;
      Slave  : out Unbounded_String);
   --  Wait for the end of a compilation and indicate that the object directory
   --  is free.

   procedure Compilation_Phase
     (Main_Project : Project_Id;
      Project_Tree : Project_Tree_Ref);

   procedure Recursive_Import (Project : Project_Id);
   --  Add to table Imports the projects imported by Project, recursively

   function Project_Extends
     (Extending : Project_Id;
      Extended  : Project_Id) return Boolean;
   --  Returns True if Extending is Extended or is extending Extended directly
   --  or indirectly.

   function Directly_Imports
     (Project  : Project_Id;
      Imported : Project_Id) return Boolean;
   --  Returns True if Project directly withs Imported or a project extending
   --  Imported.

   procedure Create_Config_File
     (For_Project  : Project_Id;
      Config       : Language_Config;
      Language     : Name_Id);
   --  Create a new config file

   function Config_File_For
     (Project        : Project_Id;
      Package_Name   : Name_Id;
      Attribute_Name : Name_Id;
      Language       : Name_Id) return Path_Information;
   --  Returns the name of a config file. Returns No_Name if there is no
   --  config file.

   procedure Create_Object_Path_File
     (Project : Project_Id; Shared : Shared_Project_Tree_Data_Access);
   --  Create a temporary file that contains the list of object directories
   --  in the correct order.

   procedure Print_Compilation_Outputs
     (For_Source : Source_Id;
      Always     : Boolean := False);
   --  In complete output mode, or when Always is True, put the outputs from
   --  last compilation to standard output and/or standard error.

   function "<" (Left, Right : Source_Id) return Boolean
     is (Left.File < Right.File);

   package Bad_Compilations_Set is new
     Containers.Indefinite_Ordered_Maps (Source_Id, String);

   Bad_Compilations : Bad_Compilations_Set.Map;
   --  Records bad compilation with the given slave name if any

   Outstanding_Compiles : Natural := 0;
   --  The number of compilation jobs currently spawned

   Slave_Initialized    : Boolean := False;
   --  Record wether the remote compilation slaves have been initialized when
   --  running in distributed mode.

   type Process_Purpose is (Compilation, Dependency);
   --  A type to distinguish between compilation jobs and dependency file
   --  building jobs.

   type Process_Data is record
      Process        : GPR.Compilation.Id  :=
                         GPR.Compilation.Invalid_Process;
      Source         : Queue.Source_Info  := Queue.No_Source_Info;
      Source_Project : Project_Id         := null;
      Mapping_File   : Path_Name_Type     := No_Path;
      Purpose        : Process_Purpose    := Compilation;
      Options        : String_Vectors.Vector;
   end record;
   --  Data recorded for each spawned jobs, compilation of dependency file
   --  building.

   No_Process_Data : constant Process_Data :=
                       (Process        => GPR.Compilation.Invalid_Process,
                        Source         => Queue.No_Source_Info,
                        Source_Project => null,
                        Mapping_File   => No_Path,
                        Purpose        => Compilation,
                        Options        => String_Vectors.Empty_Vector);

   package Compilation_Htable is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Compilation.Process.Header_Num,
      Element    => Process_Data,
      No_Element => No_Process_Data,
      Key        => GPR.Compilation.Id,
      Hash       => Hash,
      Equal      => GPR.Compilation."=");
   --  Hash table to keep data for all spawned jobs

   package Naming_Data_Vectors is new Ada.Containers.Vectors
     (Positive, Lang_Naming_Data);

   Naming_Datas : Naming_Data_Vectors.Vector;
   --  Naming data when creating config files

   package Imports is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => Boolean,
      No_Element => False,
      Key        => Project_Id,
      Hash       => Hash,
      Equal      => "=");
   --  When --direct-import-only is used, contains the project ids a non Ada
   --  source is allowed to import source from.

   Included_Sources : Source_Vectors.Vector;

   Subunits         : String_Vectors.Vector;
   --  A table to store the subunit names when switch --no-split-units is used

   ------------------------------
   -- Add_Compilation_Switches --
   ------------------------------

   Inner_Cargs : constant String := "-inner-cargs";
   --  When the --compiler-pkg-subst switch is given, this is used to pass
   --  switches from "package Compiler" to the ASIS tool and thence through to
   --  the actual compiler.

   procedure Add_Compilation_Switches (Source : Source_Id) is
      procedure Process_One_Package (Pkg_Name : Name_Id);
      --  Get the switches for the named package

      -------------------------
      -- Process_One_Package --
      -------------------------

      procedure Process_One_Package (Pkg_Name : Name_Id) is
         Options : Variable_Value;
         Ignored : Boolean;
      begin
         Get_Switches
           (Source, Pkg_Name, Project_Tree, Options, Ignored);

         if Options /= Nil_Variable_Value then
            declare
               List            : String_List_Id := Options.Values;
               Element         : String_Element;
            begin
               while List /= Nil_String loop
                  Element := Project_Tree.Shared.String_Elements.Table (List);

                  --  Ignore empty options

                  if Element.Value /= Empty_String then
                     Add_Option_Internal_Codepeer
                       (Value       => Get_Option (Element.Value),
                        To          => Compilation_Options,
                        Display     => True);
                  end if;

                  List := Element.Next;
               end loop;
            end;
         end if;
      end Process_One_Package;

   begin
      --  If the --compiler-pkg-subst switch was given, get switches from the
      --  relevant package (e.g. "package Pretty_Printer").

      if Compiler_Pkg_Subst /= No_Name then
         Process_One_Package (Compiler_Pkg_Subst);
         Add_Option_Internal_Codepeer
           (Value       => Inner_Cargs,
            To          => Compilation_Options,
            Display     => True);
      end if;

      --  Always get switches from "package Compiler". If the
      --  --compiler-pkg-subst switch was given, these are preceded by
      --  -inner-cargs (see above) to indicate that the ASIS tool should pass
      --  them along to gcc.

      Process_One_Package (Name_Compiler);
   end Add_Compilation_Switches;

   -------------------
   -- Await_Compile --
   -------------------

   procedure Await_Compile
     (Source : out Queue.Source_Info;
      OK     : out Boolean;
      Slave  : out Unbounded_String)
   is
      Process   : GPR.Compilation.Id;
      Comp_Data : Process_Data;
      Language  : Language_Ptr;
      Config    : Language_Config;

   begin
      loop
         Source := Queue.No_Source_Info;

         Wait_Result (Process, OK);

         if Process = GPR.Compilation.Invalid_Process then
            return;
         end if;

         Comp_Data := Compilation_Htable.Get (Process);

         if Comp_Data /= No_Process_Data then
            Source := Comp_Data.Source;

            Queue.Set_Obj_Dir_Free (Source.Id.Project.Object_Directory.Name);

            if Comp_Data.Purpose = Compilation then
               Print_Compilation_Outputs
                 (Source.Id, Always => not No_Complete_Output);

               if OK then
                  --  We created a new dependency file, so reset the attributes
                  --  of the old one.

                  Source.Id.Dep_TS := Unknown_Attributes;

                  if not Comp_Data.Options.Is_Empty
                    and then Source.Id.Switches_Path /= No_Path
                    and then Opt.Check_Switches
                  then
                     --  First, update the time stamp of the object file that
                     --  will be written in the switches file.

                     Source.Id.Object_TS := File_Stamp (Source.Id.Object_Path);
                     GPR.Util.Update_File_Stamp
                       (Source.Id.Object_Path, Source.Id.Object_TS);

                     --  Write the switches file, now that we have the updated
                     --  time stamp for the object file.

                     declare
                        File : Text_IO.File_Type;

                     begin
                        Create
                          (File,
                           Out_File,
                           Get_Name_String (Source.Id.Switches_Path));

                        Put_Line (File, String (Source.Id.Object_TS));

                        for Arg of Comp_Data.Options loop
                           Put_Line (File, Arg);
                        end loop;

                        Close (File);

                     exception
                        when others =>
                           Fail_Program
                             (Source.Tree,
                              "could not create switches file """ &
                              Get_Name_String (Source.Id.Switches_Path) & '"');
                     end;

                     --  For all languages other than Ada, update the time
                     --  stamp of the object file as it is written in the
                     --  global archive dependency file. For all languages,
                     --  update the time stamp of the object file if it is in
                     --  a library project.

                  elsif Source.Id.Language.Config.Dependency_Kind not in
                        ALI_Dependency
                    or else Source.Id.Project.Library
                  then
                     Source.Id.Object_TS := File_Stamp (Source.Id.Object_Path);
                     GPR.Util.Update_File_Stamp
                       (Source.Id.Object_Path, Source.Id.Object_TS);
                  end if;

               else
                  Set_Failed_Compilation_Status (Comp_Data.Source_Project);

                  Slave := To_Unbounded_String (Get_Slave_For (Process));
               end if;

               Language := Source.Id.Language;

               --  If there is a mapping file used, recycle it in the hash
               --  table of the language.

               if Comp_Data.Mapping_File /= No_Path
                 and then Language /= No_Language_Index
               then
                  Mapping_Files_Htable.Set
                    (T => Language.Mapping_Files,
                     K => Comp_Data.Mapping_File,
                     E => Comp_Data.Mapping_File);
               end if;

               Config := Language.Config;

               if OK
                 and then Config.Dependency_Kind = Makefile
                 and then Config.Compute_Dependency /= No_Name_List
               then
                  declare
                     Current_Dir : constant Dir_Name_Str := Get_Current_Dir;

                     List      : Name_List_Index :=
                                   Config.Compute_Dependency;
                     Nam       : Name_Node :=
                                   Source.Tree.Shared.Name_Lists.Table (List);
                     Exec_Name : constant String :=
                                   Get_Name_String (Nam.Name);
                     Exec_Path : OS_Lib.String_Access;
                  begin
                     Change_Dir
                       (Get_Name_String
                          (Source.Id.Project.Object_Directory.Display_Name));
                     Comp_Data.Mapping_File := No_Path;
                     Comp_Data.Purpose := Dependency;

                     --  ??? We search for it on the PATH for every file,
                     --  this is very inefficient
                     Exec_Path := Locate_Exec_On_Path (Exec_Name);

                     if Exec_Path = null then
                        Fail_Program
                          (Source.Tree,
                           "unable to find dependency builder " & Exec_Name);
                     end if;

                     List := Nam.Next;
                     Compilation_Options.Clear;

                     if List = No_Name_List then
                        Name_Len := 0;

                     else
                        loop
                           Nam := Source.Tree.Shared.Name_Lists.Table (List);
                           List := Nam.Next;

                           if List = No_Name_List then
                              Get_Name_String (Nam.Name);
                              exit;
                           end if;

                           Add_Option
                             (Nam.Name, Compilation_Options, Opt.Verbose_Mode);
                        end loop;
                     end if;

                     Get_Name_String_And_Append (Source.Id.Path.Display_Name);
                     Add_Option
                       (Name_Buffer (1 .. Name_Len),
                        Compilation_Options,
                        Opt.Verbose_Mode,
                        Simple_Name => not Opt.Verbose_Mode);

                     if not Opt.Quiet_Output then
                        if Opt.Verbose_Mode then
                           Put (Exec_Path.all);
                        else
                           Put (Exec_Name);
                        end if;

                        Put (" ");

                        for Option of Compilation_Options loop
                           if Option.Displayed then
                              Put (Option.Name);
                              Put (" ");
                           end if;
                        end loop;

                        New_Line;
                     end if;

                     Comp_Data.Process :=
                       Run
                         (Executable  => Exec_Path.all,
                          Options     => Options_List (Compilation_Options),
                          Project     => Comp_Data.Source_Project,
                          Obj_Name    => Get_Name_String (Source.Id.Object),
                          Output_File => Get_Name_String (Source.Id.Dep_Path),
                          Err_To_Out  => True,
                          Force_Local => True);

                     Compilation_Htable.Set (Comp_Data.Process, Comp_Data);

                     Free (Exec_Path);

                     Change_Dir (Current_Dir);
                  end;

               else
                  Outstanding_Compiles := Outstanding_Compiles - 1;

                  if Opt.Use_GNU_Make_Jobserver then
                     Jobserver.Unregister_Token_Id (Id => Process);
                  end if;

                  return;
               end if;

            elsif Comp_Data.Purpose = Dependency then
               Outstanding_Compiles := Outstanding_Compiles - 1;

               if Opt.Use_GNU_Make_Jobserver then
                  Jobserver.Unregister_Token_Id (Id => Process);
               end if;

               return;
            end if;
         end if;
      end loop;
   end Await_Compile;

   ---------------------
   -- Config_File_For --
   ---------------------

   function Config_File_For
     (Project        : Project_Id;
      Package_Name   : Name_Id;
      Attribute_Name : Name_Id;
      Language       : Name_Id) return Path_Information
   is
      function Normalize_Path
        (Path    : Path_Name_Type;
         Project : Project_Id) return String
      is
        (GNAT.OS_Lib.Normalize_Pathname
           (Name      => Get_Name_String (Path),
            Directory => Get_Name_String (Project.Directory.Display_Name)));
      --  Returns an normalized path for a config file

      Config_Package  : constant Package_Id :=
                          Value_Of
                            (Name        => Package_Name,
                             In_Packages => Project.Decl.Packages,
                             Shared      => Project_Tree.Shared);

      Config_Variable : Variable_Value :=
                          Value_Of
                            (Name                    => Language,
                             Attribute_Or_Array_Name => Attribute_Name,
                             In_Package              => Config_Package,
                             Shared                  => Project_Tree.Shared);

   begin
      --  Get the config pragma attribute when the language is Ada and the
      --  config file attribute is not declared.

      if Config_Variable = Nil_Variable_Value
        and then Config_Package /= No_Package
        and then Language = Name_Ada
      then
         Config_Variable :=
           Value_Of
             (Variable_Name =>
                (if Attribute_Name = Name_Global_Config_File
                 then Name_Global_Configuration_Pragmas
                 elsif Attribute_Name = Name_Local_Config_File
                 then Name_Local_Configuration_Pragmas
                 else raise Program_Error with
                   "Unexpected " & Get_Name_String (Attribute_Name)),
              In_Variables => Project_Tree.Shared.Packages.Table
                                 (Config_Package).Decl.Attributes,
              Shared       => Project_Tree.Shared);
      end if;

      if Config_Variable = Nil_Variable_Value
        or else Config_Variable.Value = Snames.The_Empty_String
      then
         return No_Path_Information;

      else
         declare
            Path : String :=
                     Normalize_Path
                       (Path_Name_Type (Config_Variable.Value),
                        Config_Variable.Project);
            Result : Path_Information;
         begin
            Result.Display_Name := Get_Path_Name_Id (Path);
            Canonical_Case_File_Name (Path);
            Result.Name := Get_Path_Name_Id (Path);

            return Result;
         end;
      end if;
   end Config_File_For;

   ------------------------
   -- Create_Config_File --
   ------------------------

   procedure Create_Config_File
     (For_Project : Project_Id;
      Config      : Language_Config;
      Language    : Name_Id)
   is

      File_Name : Path_Name_Type  := No_Path;
      File      : File_Descriptor := Invalid_FD;

      Source   : Source_Id;
      Iter     : Source_Iterator;

      procedure Check
        (Project : Project_Id;
         Tree    : Project_Tree_Ref;
         Dummy   : in out Boolean);
      --  Check the naming schemes of the different projects of the project
      --  tree. For each different naming scheme issue the pattern config
      --  declarations.

      procedure Check_Temp_File;
      --  Check if a temp file has been created. If not, create one

      procedure Copy_Config_File
        (Project        : Project_Id;
         Package_Name   : Name_Id;
         Attribute_Name : Name_Id;
         Language       : Name_Id);
      --  If a specified config file exists, copy it in the temporary config
      --  file.

      procedure Put_Line (File : File_Descriptor; S : String);
      --  Output procedure, analogous to normal Text_IO proc of same name

      -----------
      -- Check --
      -----------

      procedure Check
        (Project : Project_Id;
         Tree    : Project_Tree_Ref;
         Dummy   : in out Boolean)
      is
         pragma Unreferenced (Dummy, Tree);
         Lang_Id : Language_Ptr := Project.Languages;

         Current_Naming : Natural := 0;

         procedure Replace;

         -------------
         -- Replace --
         -------------

         procedure Replace is
            Cur : Positive := 1;

            procedure Substitute (N : File_Name_Type);
            procedure Substitute (Name : String);

            ----------------
            -- Substitute --
            ----------------

            procedure Substitute (N : File_Name_Type) is
            begin
               if N = No_File then
                  Cur := Cur + 1;

               else
                  Substitute (Get_Name_String (N));
               end if;
            end Substitute;

            procedure Substitute (Name : String) is
            begin
               Name_Buffer
                 (Cur + Name'Length .. Name_Len - 2 + Name'Length) :=
                 Name_Buffer (Cur + 2 .. Name_Len);
               Name_Buffer (Cur .. Cur + Name'Length - 1) := Name;
               Name_Len := Name_Len - 2 + Name'Length;
               Cur := Cur + Name'Length;
            end Substitute;

         begin
            while Cur < Name_Len loop
               if Name_Buffer (Cur) = '%' then
                  case Name_Buffer (Cur + 1) is
                     when 'b' =>
                        Substitute (Lang_Id.Config.Naming_Data.Body_Suffix);

                     when 's' =>
                        Substitute (Lang_Id.Config.Naming_Data.Spec_Suffix);

                     when 'd' =>
                        Substitute
                          (Lang_Id.Config.Naming_Data.Dot_Replacement);

                     when 'c' =>
                        Substitute
                          (Image (Lang_Id.Config.Naming_Data.Casing));

                     when '%' =>
                        Name_Buffer (Cur .. Name_Len - 1) :=
                          Name_Buffer (Cur + 1 .. Name_Len);
                        Name_Len := Name_Len - 1;
                        Cur := Cur + 1;

                     when others =>
                        Cur := Cur + 1;
                  end case;

               else
                  Cur := Cur + 1;
               end if;
            end loop;
         end Replace;

      begin
         if Current_Verbosity = High then
            Put ("Checking project file """);
            Put (Get_Name_String (Project.Name));
            Put (""".");
            New_Line;
         end if;

         while Lang_Id /= No_Language_Index loop
            exit when Lang_Id.Name = Language;
            Lang_Id := Lang_Id.Next;
         end loop;

         if Lang_Id /= No_Language_Index then
            Current_Naming :=
              Natural (Naming_Datas.Find_Index (Lang_Id.Config.Naming_Data));

            if Current_Naming = 0 then
               Naming_Datas.Append (Lang_Id.Config.Naming_Data);

               Check_Temp_File;

               if Lang_Id.Config.Config_Spec_Pattern /= No_Name then
                  Get_Name_String (Lang_Id.Config.Config_Spec_Pattern);
                  Replace;
                  Put_Line (File, Name_Buffer (1 .. Name_Len));
               end if;

               if Lang_Id.Config.Config_Body_Pattern /= No_Name then
                  Get_Name_String (Lang_Id.Config.Config_Body_Pattern);
                  Replace;
                  Put_Line (File, Name_Buffer (1 .. Name_Len));
               end if;
            end if;
         end if;
      end Check;

      ---------------------
      -- Check_Temp_File --
      ---------------------

      procedure Check_Temp_File is
      begin
         if File = Invalid_FD then
            Tempdir.Create_Temp_File (File, Name => File_Name);

            if File = Invalid_FD then
               Fail_Program
                 (Project_Tree,
                  "unable to create temporary configuration pragmas file");

            else
               Record_Temp_File (Project_Tree.Shared, File_Name);

               if Opt.Verbosity_Level > Opt.Low then
                  Put ("Creating temp file """);
                  Put (Get_Name_String (File_Name));
                  Put_Line ("""");
               end if;
            end if;
         end if;
      end Check_Temp_File;

      ----------------------
      -- Copy_Config_File --
      ----------------------

      procedure Copy_Config_File
        (Project        : Project_Id;
         Package_Name   : Name_Id;
         Attribute_Name : Name_Id;
         Language       : Name_Id)
      is
         Config_File_Path : constant Path_Name_Type :=
                              Config_File_For
                                (Project, Package_Name,
                                 Attribute_Name, Language).Display_Name;
         Config_File      : Text_IO.File_Type;
         Line             : String (1 .. 1_000);
         Last             : Natural;

      begin
         if Config_File_Path /= No_Path then
            begin
               Open (Config_File, In_File, Get_Name_String (Config_File_Path));

            exception
               when others =>
                  Fail_Program
                    (Project_Tree,
                     "unable to open config file "
                     & Get_Name_String (Config_File_Path));
            end;

            Check_Temp_File;

            while not End_Of_File (Config_File) loop
               Get_Line (Config_File, Line, Last);
               Put_Line (File, Line (1 .. Last));
            end loop;

            Close (Config_File);
         end if;
      end Copy_Config_File;

      --------------
      -- Put_Line --
      --------------

      procedure Put_Line (File : File_Descriptor; S : String) is
         S0   : String (1 .. S'Length + 1);
         Last : Natural;

      begin
         --  Add an ASCII.LF to the string. As this config file is supposed to
         --  be used only by the compiler, we don't care about the characters
         --  for the end of line. In fact we could have put a space, but
         --  it is more convenient to be able to read gnat.adc during
         --  development, for which the ASCII.LF is fine.

         S0 (1 .. S'Length) := S;
         S0 (S0'Last) := ASCII.LF;
         Last := Write (File, S0'Address, S0'Length);

         if Last /= S'Length + 1 then
            Fail_Program (Project_Tree, "Disk full");
         end if;

         if Current_Verbosity = High then
            Put_Line (S);
         end if;
      end Put_Line;

      procedure Check_All_Projects is
        new For_Every_Project_Imported (Boolean, Check);
      Dummy : Boolean := False;

      --  Start of processing for Create_Config_File

   begin
      --  Nothing to do if config has already been checked

      if For_Project.Config_Checked then
         return;
      end if;

      if Config.Config_File_Unique then
         --  Copy an eventual global config file

         Copy_Config_File
           (Main_Project, Name_Builder, Name_Global_Config_File, Language);

         --  Copy an eventual local config file

         Copy_Config_File
           (For_Project, Name_Compiler, Name_Local_Config_File, Language);
      end if;

      For_Project.Config_Checked := True;

      Naming_Datas.Clear;

      Check_All_Projects (For_Project, Project_Tree, Dummy);

      --  Visit all the units and issue the config declarations for those that
      --  need one.

      Iter := For_Each_Source (Project_Tree);

      loop
         Source := GPR.Element (Iter);
         exit when Source = No_Source;

         if Source.Language.Name = Language
           and then Source.Naming_Exception /= No
           and then Source.Unit /= No_Unit_Index
           and then not Source.Locally_Removed
           and then Source.Replaced_By = No_Source
         then
            Name_Len := 0;

            if Source.Kind = Spec then
               if Source.Index = 0 and then Config.Config_Spec /= No_Name then
                  Get_Name_String (Config.Config_Spec);

               elsif
                 Source.Index /= 0 and then Config.Config_Spec_Index /= No_Name
               then
                  Get_Name_String (Config.Config_Spec_Index);
               end if;

            else
               if Source.Index = 0 and then Config.Config_Body /= No_Name then
                  Get_Name_String (Config.Config_Body);

               elsif
                 Source.Index /= 0 and then Config.Config_Body_Index /= No_Name
               then
                  Get_Name_String (Config.Config_Body_Index);
               end if;
            end if;

            if Name_Len /= 0 then
               declare
                  Cur       : Positive := 1;
                  Unit      : constant String :=
                                Get_Name_String (Source.Unit.Name);
                  File_Name : constant String :=
                                Get_Name_String (Source.Display_File);

               begin
                  while Cur < Name_Len loop
                     if Name_Buffer (Cur) /= '%' then
                        Cur := Cur + 1;

                     else
                        case Name_Buffer (Cur + 1) is
                           when 'u' =>
                              Name_Buffer
                                (Cur + Unit'Length ..
                                   Name_Len - 2 + Unit'Length) :=
                                  Name_Buffer (Cur + 2 .. Name_Len);
                              Name_Buffer (Cur .. Cur + Unit'Length - 1) :=
                                Unit;
                              Cur := Cur + Unit'Length;
                              Name_Len := Name_Len - 2 + Unit'Length;

                           when 'f' =>
                              Name_Buffer
                                (Cur + File_Name'Length ..
                                   Name_Len - 2 + File_Name'Length) :=
                                  Name_Buffer (Cur + 2 .. Name_Len);
                              Name_Buffer
                                (Cur .. Cur + File_Name'Length - 1) :=
                                File_Name;
                              Cur := Cur + File_Name'Length;
                              Name_Len := Name_Len - 2 + File_Name'Length;

                           when 'i' =>
                              declare
                                 Index_String : constant String :=
                                   Source.Index'Img;

                              begin
                                 Name_Buffer
                                   (Cur + Index_String'Length ..
                                      Name_Len - 2 + Index_String'Length) :=
                                     Name_Buffer (Cur + 2 .. Name_Len);
                                 Name_Buffer
                                   (Cur .. Cur + Index_String'Length - 1) :=
                                   Index_String;
                                 Cur := Cur + Index_String'Length;
                                 Name_Len :=
                                   Name_Len - 2 + Index_String'Length;
                              end;

                           when '%' =>
                              Name_Buffer (Cur .. Name_Len - 1) :=
                                Name_Buffer (Cur + 1 .. Name_Len);
                              Cur := Cur + 1;
                              Name_Len := Name_Len - 1;

                           when others =>
                              Cur := Cur + 1;
                        end case;
                     end if;
                  end loop;

                  Put_Line (File, Name_Buffer (1 .. Name_Len));
               end;
            end if;
         end if;

         Next (Iter);
      end loop;

      if File /= Invalid_FD then
         Close (File);
         For_Project.Config_File_Name := File_Name;
      end if;
   end Create_Config_File;

   -----------------------------
   -- Create_Object_Path_File --
   -----------------------------

   procedure Create_Object_Path_File
     (Project : Project_Id; Shared : Shared_Project_Tree_Data_Access)
   is
      FD   : File_Descriptor;
      Name : Path_Name_Type;

      LF : constant String := (1 => ASCII.LF);

      procedure Add
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Boolean);
      --  Add the object directory of a project to the file

      ---------
      -- Add --
      ---------

      procedure Add
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Boolean)
      is
         pragma Unreferenced (In_Tree);

         Path : constant Path_Name_Type :=
                  Get_Object_Directory
                    (Project,
                     Including_Libraries => True,
                     Only_If_Ada         => False);

         Last : Natural;

         pragma Unreferenced (Last);

      begin
         if Path /= No_Path then
            Get_Name_String (Path);
            Last := Write (FD, Name_Buffer (1)'Address, Name_Len);
            Last := Write (FD, LF (1)'Address, 1);
         end if;

         Dummy := True;
      end Add;

      procedure For_All_Projects is
        new For_Every_Project_Imported (Boolean, Add);

      Status : Boolean := False;
      pragma Warnings (Off, Status);

   begin
      GPR.Env.Create_Temp_File (Shared, FD, Name, "object path file");
      Project.Object_Path_File := Name;

      For_All_Projects
        (Project, Project_Tree, Status, Include_Aggregated => True);

      Close (FD, Status);
   end Create_Object_Path_File;

   ----------------------
   -- Recursive_Import --
   ----------------------

   procedure Recursive_Import (Project : Project_Id) is
      Ext : constant Project_Id := Project.Extends;
      L   : Project_List := Project.Imported_Projects;

   begin
      if Ext /= No_Project
        and then not Imports.Get (Ext)
      then
         Imports.Set (Ext, True);
         Recursive_Import (Ext);
      end if;

      while L /= null loop
         if not Imports.Get (L.Project) then
            Imports.Set (L.Project, True);
            Recursive_Import (L.Project);
         end if;

         L := L.Next;
      end loop;
   end Recursive_Import;

   ----------------------
   -- Directly_Imports --
   ----------------------

   function Directly_Imports
     (Project  : Project_Id;
      Imported : Project_Id) return Boolean
   is
      L : Project_List := Project.Imported_Projects;
      P : Project_Id;

   begin
      while L /= null loop
         P := L.Project;
         while P /= No_Project loop
            if Imported = P then
               return True;
            end if;

            P := P.Extends;
         end loop;

         L := L.Next;
      end loop;

      return False;
   end Directly_Imports;

   -------------------------------
   -- Print_Compilation_Outputs --
   -------------------------------

   procedure Print_Compilation_Outputs
     (For_Source : Source_Id;
      Always     : Boolean := False)
   is
      procedure Display_Content (Stream : File_Type; File_Path : String);
      --  Display content of the given Filename

      ---------------------
      -- Display_Content --
      ---------------------

      procedure Display_Content (Stream : File_Type; File_Path : String) is
         File : Ada.Text_IO.File_Type;
         Line : String (1 .. 1_024);
         Last : Natural;
         Print_New_Line : Boolean := False;
      begin
         if OS_Lib.Is_Regular_File (File_Path) then
            Open (File, In_File, File_Path);

            while not End_Of_File (File) loop
               Get_Line (File, Line, Last);
               if Last = Line'Last then
                  Put (Stream, Line (1 .. Last));
                  Print_New_Line := True;
               else
                  Put_Line (Stream, Line (1 .. Last));
               end if;
            end loop;

            if Print_New_Line then
               Put_Line (Stream, "");
            end if;
            Close (File);
         end if;
      end Display_Content;

   begin
      if Complete_Output or else Always then
         declare
            Proj      : constant Project_Id :=
                          Ultimate_Extending_Project_Of (For_Source.Project);
            File_Path : constant String :=
                          Get_Name_String (Proj.Object_Directory.Name)
                          & Directory_Separator
                          & Get_Name_String (For_Source.File);
         begin
            Display_Content (Standard_Output, File_Path & ".stdout");
            Display_Content (Standard_Error, File_Path & ".stderr");
         end;
      end if;
   end Print_Compilation_Outputs;

   ---------
   -- Run --
   ---------

   procedure Run is

      procedure Do_Compile (Project : Project_Id; Tree : Project_Tree_Ref);

      ----------------
      -- Do_Compile --
      ----------------

      procedure Do_Compile (Project : Project_Id; Tree : Project_Tree_Ref) is
      begin
         if Builder_Data (Tree).Need_Compilation then
            Compilation_Phase (Project, Tree);

            if Total_Errors_Detected > 0
              or else not Bad_Compilations.Is_Empty
            then
               --  If switch -k or -jnn (with nn > 1), output a summary of the
               --  sources that could not be compiled.

               if (Opt.Keep_Going or else Get_Maximum_Processes > 1)
                 and then not Bad_Compilations.Is_Empty
                 and then not Opt.No_Exit_Message
               then
                  New_Line;

                  for Index in Bad_Compilations.Iterate loop
                     declare
                        Source : constant Source_Id :=
                                   Bad_Compilations_Set.Key (Index);
                        Slave  : constant String :=
                                   Bad_Compilations_Set.Element (Index);
                     begin
                        if Source /= No_Source then
                           Put ("   compilation of ");
                           Put (Get_Name_String (Source.Display_File));
                           Put (" failed");
                           if Slave /= "" then
                              Put (" on " & Slave);
                           end if;
                           New_Line;
                        end if;
                     end;
                  end loop;

                  New_Line;
               end if;

               if Exit_Code = Osint.E_Success then
                  Exit_Code := (if Bad_Compilations.Is_Empty then E_Fatal
                                else E_Subtool);
               end if;

               if Opt.Keep_Going and then Project.Qualifier = Aggregate then
                  Bad_Compilations.Clear;

               else
                  if Distributed_Mode and then Slave_Initialized then
                     GPR.Compilation.Slave.Unregister_Remote_Slaves;
                  end if;

                  Compilation_Phase_Failed
                    (Tree, Exit_Code, No_Message => Opt.No_Exit_Message);
               end if;
            end if;
         end if;
      end Do_Compile;

      procedure Compile_All is new For_Project_And_Aggregated (Do_Compile);

   begin
      Compile_All (Main_Project, Project_Tree);

      --  Unregister the slaves and get back compiled object code. This is a
      --  nop if no compilation has been done.

      GPR.Compilation.Slave.Unregister_Remote_Slaves;
   end Run;

   -----------------------
   -- Compilation_Phase --
   -----------------------

   procedure Compilation_Phase
     (Main_Project : Project_Id;
      Project_Tree : Project_Tree_Ref)
   is
      type Local_Project_Data is record
         Include_Language       : Language_Ptr := No_Language_Index;
         --  Prepared arguments for "include" parameters (-I or include file).
         --  These are specific to each language and project.

         Include_Path_File      : Path_Name_Type;
         --  The path name of the source search directory file

         Imported_Dirs_Switches : Argument_List_Access;
         --  List of the source search switches (-I<source dir>) to be used
         --  when compiling.

         Include_Path           : OS_Lib.String_Access := null;
         --  The search source path for the project. Used as the value for an
         --  environment variable, specified by attribute Include_Path
         --  (<langu>). The names of the environment variables are in component
         --  Include_Path of the records Language_Config.

         Include_Switches_Spec_File : Path_Name_Type;

      end record;
      --  project-specific data required for this procedure. These are not
      --  stored in the Project_Data record so that projects kept in memory do
      --  not have to allocate space for these temporary data

      No_Local_Project_Data : constant Local_Project_Data :=
                             (Include_Language           => No_Language_Index,
                              Include_Path               => null,
                              Imported_Dirs_Switches     => null,
                              Include_Path_File          => No_Path,
                              Include_Switches_Spec_File => No_Path);

      package Local_Projects_HT is new Dynamic_HTables.Simple_HTable
        (Header_Num => GPR.Header_Num,
         Element    => Local_Project_Data,
         No_Element => No_Local_Project_Data,
         Key        => Project_Id,
         Hash       => GPR.Hash,
         Equal      => "=");

      Local_Projects : Local_Projects_HT.Instance;

      Keep_Dep_File : Boolean := False;
      --  We need to keep dependency file in some error cases for diagnostic

      The_Config_Paths : Config_Paths
                           (1 .. 2 + Natural (Cmd_Line_Adc_Files.Length));
      --  Paths of eventual global and local configuration pragmas files
      --  and files from -gnatec= command line parameters.

      Last_Config_Path : Natural := 0;

      procedure Add_Config_File_Switch
        (Config    : Language_Config;
         Path_Name : Path_Name_Type);

      procedure Record_ALI_For
        (Source_Identity : Queue.Source_Info;
         The_ALI         : ALI.ALI_Id := ALI.No_ALI_Id);
      --  Record the Id of an ALI file in Good_ALI table.
      --  The_ALI can contain the pre-parsed ali file, to save time.
      --  Tree is the tree to which Source_Identity belongs

      function Phase_2_Makefile (Src_Data : Queue.Source_Info) return Boolean;
      function Phase_2_ALI (Src_Data : Queue.Source_Info) return Boolean;
      --  Process Wait_For_Available_Slot depending on Src_Data.Dependency type
      --  This returns whether the compilation is considered as successful or
      --  not.

      procedure Set_Options_For_File (Id : Source_Id);
      --  Prepare the compiler options to use when building Id

      procedure Process_Project_Phase_1 (Source : Queue.Source_Info);
      --  If some compilation is needed for this project, perform it

      function Must_Exit_Because_Of_Error return Boolean;
      --  Return True if there were errors and the user decided to exit in such
      --  a case. This waits for any outstanding compilation.

      function Check_Switches_File (Id : Source_Id) return Boolean;
      --  Check in its switches file where Id was compiled with the same
      --  switches

      procedure Update_Object_Path
        (Id : Source_Id; Source_Project : Project_Id);
      --  Update, if necessary, the path of the object file, of the dependency
      --  file and of the switches file, in the case of the compilation of a
      --  source in an extended project, when the source is in a project being
      --  extended.

      procedure Add_Dependency_Options (Id : Source_Id);
      --  Add switches to the compilation command line to create the
      --  dependency file

      procedure Add_Object_File_Switches (Id : Source_Id);
      --  If there are switches to specify the name of the object file, add
      --  them.

      procedure Add_Object_Path_Switches (Id : Source_Id);
      --  If attribute Compiler'Object_Path_Switches has been specified, create
      --  the temporary object path file, if not already done, and add the
      --  switch(es) to the invocation of the compiler.

      procedure Get_Config_Paths
        (Id             : Source_Id;
         Source_Project : Project_Id);
      --  Find the config files for the source and put their paths in
      --  The_Config_Paths.

      procedure Add_Config_File_Switches
        (Id             : Source_Id;
         Source_Project : Project_Id);
      --  If Config_File_Switches is specified, check if a config file need to
      --  be specified. Return the path to the config file

      procedure Add_Trailing_Switches (Id : Source_Id);
      --  Add the trailing required switches, if any, so that they will be put
      --  in the switches file.

      procedure Add_Name_Of_Source_Switches (Id : Source_Id);
      --  Add the name of the source to be compiled

      function Add_Mapping_File_Switches
        (Source         : Queue.Source_Info;
         Source_Project : Project_Id) return Path_Name_Type;
      --  If the compiler supports mapping files, add the necessary switch.
      --  Returns the name of the mapping file to use (or No_File)

      procedure Add_Multi_Unit_Switches (Id : Source_Id);
      --  Add, if needed, the required switches to compile a multi-unit source
      --  file.

      procedure Spawn_Compiler_And_Register
        (Source                 : Queue.Source_Info;
         Source_Project         : Project_Id;
         Compiler_Path          : String;
         Mapping_File_Path      : Path_Name_Type;
         Last_Switches_For_File : Integer);
      --  Spawn the compiler with the arguments currently set in
      --  Compiler_Options. It registers the process we just spawned, so that
      --  we start monitoring it.
      --  This also displays on the output the command we are spawning.
      --  Last_Switches_For_File is the index in Compilation_Options of the
      --  last switch that should be written to the switches file. All
      --  following switches are not output in that file.

      function Get_Compatible_Languages (Lang : Language_Ptr) return Name_Ids;
      --  Return the list of languages that Id could potentially include (for
      --  instance "C" if Id is a "C++" file. This also includes Id's own
      --  language.

      procedure Prepare_Imported_Dirs_Switches
        (Data    : out Local_Project_Data;
         Project : Project_Id;
         Lang    : Language_Ptr);
      --  Add the switches for include directories to the command line (these
      --  are the "-I" switches in the case of C for instance).

      procedure Prepare_Include_Path_File
        (Data    : out Local_Project_Data;
         Project : Project_Id;
         Lang    : Language_Ptr);
      --  Create a file to pass the include directories to the compiler

      procedure Start_Compile_If_Possible;
      --  Checks if there is more work that we can do (ie the Queue is non
      --  empty). If there is, do it only if we have not yet used up all the
      --  available processes.

      procedure Wait_For_Available_Slot;
      --  Check if we should wait for a compilation to finish. This is the case
      --  if all the available processes are busy compiling sources or there is
      --  nothing else to do (that is the Q is empty and there are outstanding
      --  compilations).

      procedure Set_Env_For_Include_Dirs
        (Id : Source_Id;  Source_Project : Project_Id);
      --  Set environment variables or switches to pass the include directories
      --  to the compiler

      procedure Check_Interface_And_Indirect_Imports
        (The_ALI      : ALI.ALI_Id;
         Src_Data     : Queue.Source_Info;
         Success      : in out Boolean);
      --  From the given ALI data and the associated source Src_Data, checks
      --  the withed units for the following error cases:
      --    - The unit is not in the interface of the source's project
      --    - The unit is from an indirect import and the --no-indirect-import
      --      flag is set.
      --  Success is set to False if those occur.

      ------------------------------------------
      -- Check_Interface_And_Indirect_Imports --
      ------------------------------------------

      procedure Check_Interface_And_Indirect_Imports
        (The_ALI      : ALI.ALI_Id;
         Src_Data     : Queue.Source_Info;
         Success      : in out Boolean)
      is
         Sfile    : File_Name_Type;
         Afile    : File_Name_Type;
         Source_2 : Source_Id;

      begin
         for J in ALI.ALIs.Table (The_ALI).First_Unit ..
           ALI.ALIs.Table (The_ALI).Last_Unit
         loop
            for K in ALI.Units.Table (J).First_With ..
              ALI.Units.Table (J).Last_With
            loop
               if not
                 ALI.Withs.Table (K).Implicit_With_From_Instantiation
               then
                  Sfile := ALI.Withs.Table (K).Sfile;

                  --  Skip generics

                  if Sfile /= No_File then

                     --  Look for this source

                     Afile := ALI.Withs.Table (K).Afile;
                     Source_2 := Source_Files_Htable.Get
                       (Src_Data.Tree.Source_Files_HT, Sfile);

                     while Source_2 /= No_Source loop
                        if Is_Compilable (Source_2)
                          and then  Source_2.Dep_Name = Afile
                        then
                           case Source_2.Kind is
                              when Spec => null;

                              when Impl =>
                                 if Is_Subunit (Source_2) then
                                    Source_2 := No_Source;
                                 end if;

                              when Sep =>
                                 Source_2 := No_Source;
                           end case;

                           exit;
                        end if;

                        Source_2 := Source_2.Next_With_File_Name;
                     end loop;

                     --  If it is the source of a project that is not the
                     --  project of the source just compiled, check if it
                     --  is allowed to be imported.

                     if Source_2 /= No_Source then
                        if not Project_Extends
                          (Src_Data.Id.Project, Source_2.Project)
                          and then
                            not Project_Extends
                              (Source_2.Project, Src_Data.Id.Project)
                        then
                           if not Indirect_Imports
                             and then not Directly_Imports
                               (Src_Data.Id.Project, Source_2.Project)
                           then
                              --  It is in a project that is not directly
                              --  imported. Report an error and
                              --  invalidate the compilation.

                              Put ("Unit """);
                              Put (Get_Name_String (Src_Data.Id.Unit.Name));
                              Put (""" cannot import unit """);
                              Put (Get_Name_String (Source_2.Unit.Name));
                              Put_Line (""":");

                              Put ("  """);
                              Put
                                (Get_Name_String
                                   (Src_Data.Id.Project.Display_Name));
                              Put (""" does not directly import project """);
                              Put
                                (Get_Name_String
                                   (Source_2.Project.Display_Name));
                              Put_Line ("""");

                              Exit_Code := E_General;
                              Success   := False;

                           elsif not Source_2.In_Interfaces then
                              --  It is not an interface of its project.
                              --  Report an error and invalidate the
                              --  compilation.

                              Put ("Unit """);
                              Put
                                (Get_Name_String
                                   (Src_Data.Id.Unit.Name));
                              Put (""" cannot import unit """);
                              Put
                                (Get_Name_String (Source_2.Unit.Name));
                              Put_Line (""":");

                              Put
                                ("  it is not part of the "
                                 & "interfaces of its project """);
                              Put
                                (Get_Name_String
                                   (Source_2.Project.Display_Name));
                              Put_Line ("""");

                              Success := False;
                           end if;
                        end if;
                     end if;
                  end if;
               end if;
            end loop;
         end loop;
      end Check_Interface_And_Indirect_Imports;

      ----------------------------
      -- Add_Config_File_Switch --
      ----------------------------

      procedure Add_Config_File_Switch
        (Config    : Language_Config;
         Path_Name : Path_Name_Type)
      is
         List : Name_List_Index := Config.Config_File_Switches;
         Nam  : Name_Node;

      begin
         while List /= No_Name_List loop
            Nam := Project_Tree.Shared.Name_Lists.Table (List);
            Get_Name_String (Nam.Name);

            if Nam.Next = No_Name_List then
               Get_Name_String_And_Append (Path_Name);
            end if;

            Add_Option
              (Name_Buffer (1 .. Name_Len),
               To      => Compilation_Options,
               Display => Opt.Verbose_Mode);

            List := Nam.Next;
         end loop;
      end Add_Config_File_Switch;

      --------------------
      -- Record_ALI_For --
      --------------------

      procedure Record_ALI_For
        (Source_Identity : Queue.Source_Info;
         The_ALI         : ALI.ALI_Id := ALI.No_ALI_Id)
      is
         Local_ALI : ALI.ALI_Id := The_ALI;
         Text      : Text_Buffer_Ptr;

      begin
         if The_ALI = ALI.No_ALI_Id then
            Text := Read_Library_Info_From_Full
              (File_Name_Type (Source_Identity.Id.Dep_Path),
               Source_Identity.Id.Dep_TS'Access);

            if Text /= null then
               --  Read the ALI file but read only the necessary lines

               Local_ALI :=
                 ALI.Scan_ALI
                   (File_Name_Type (Source_Identity.Id.Dep_Path),
                    Text,
                    Ignore_ED     => False,
                    Err           => True,
                    Read_Lines    => "W");
               Free (Text);
            end if;
         end if;

         if Local_ALI /= ALI.No_ALI_Id then
            Queue.Insert_Withed_Sources_For (Local_ALI, Source_Identity.Tree);

            ALI.Initialize_ALI;
            --  ALI.Util.Initialize_ALI_Source;
         end if;
      end Record_ALI_For;

      ----------------------
      -- Phase_2_Makefile --
      ----------------------

      function Phase_2_Makefile
        (Src_Data : Queue.Source_Info) return Boolean is

         Object_Path : GNAT.OS_Lib.String_Access;
         Dep_File    : Text_File;
         Start       : Natural;
         Finish      : Natural;
         Last_Obj    : Natural;
         Was         : Boolean := False;

         type Src_Record (F_Len : Natural) is record
            File : String (1 .. F_Len);
            TS   : Time_Stamp_Type;
         end record;

         package Src_Vectors is new Ada.Containers.Indefinite_Vectors
           (Positive, Src_Record);

         Srcs : Src_Vectors.Vector;

         Compilation_OK  : Boolean := True;
         Dep_File_OK     : Boolean := False;

         Dep_Path : constant String := Get_Name_String (Src_Data.Id.Dep_Path);

      begin
         Open (Dep_File, Dep_Path);

         if Is_Valid (Dep_File) then

            Big_Loop :
            loop
               Skip_Loop :
               while not End_Of_File (Dep_File) loop
                  Get_Line (Dep_File, Name_Buffer, Name_Len);

                  if Name_Len > 0 and then Name_Buffer (1) /= '#' then
                     --  Skip a first line that is an empty continuation line

                     for J in 1 .. Name_Len - 1 loop
                        exit Skip_Loop when Name_Buffer (J) /= ' ';
                     end loop;

                     exit Skip_Loop when Name_Buffer (Name_Len) /= '\';
                  end if;
               end loop Skip_Loop;

               Start  := 1;
               Finish := Index (Name_Buffer (1 .. Name_Len), ": ");

               exit Big_Loop when Finish = 0;

               Last_Obj := Finish;
               loop
                  Last_Obj := Last_Obj - 1;
                  exit when Last_Obj = Start
                    or else Name_Buffer (Last_Obj) /= ' ';
               end loop;

               while Start < Last_Obj
                 and then Name_Buffer (Start) = ' '
               loop
                  Start := Start + 1;
               end loop;

               Object_Path := new String'(Name_Buffer (Start .. Last_Obj));
               Dep_File_OK := True;

               Start := Finish + 2;

               --  Process each line

               Line_Loop : loop
                  declare
                     Line : constant String  := Name_Buffer (1 .. Name_Len);
                     Last : constant Natural := Name_Len;

                  begin
                     Name_Loop : loop

                        --  Find the beginning of the next source path
                        --  name.

                        while Start < Last and then Line (Start) = ' ' loop
                           Start := Start + 1;
                        end loop;

                        --  Go to next line when there is a
                        --  continuation character \ at the end of the
                        --  line.

                        exit Name_Loop when Start = Last
                          and then Line (Start) = '\';

                        --  We should not be at the end of the line,
                        --  without a continuation character \.

                        exit Line_Loop when Start = Last;

                        --  Look for the end of the source path name

                        Finish := Start;

                        while Finish < Last loop
                           if Line (Finish) = '\' then
                              --  On Windows, a '\' is part of the path name,
                              --  except when it is not the first character
                              --  followed by another '\' or by a space.
                              --  On other platforms, when we are getting a '\'
                              --  that is not the last character of the line,
                              --  the next character is part of the path name,
                              --  even if it is a space.

                              if On_Windows
                                and then Finish = Start
                                and then Line (Finish + 1) = '\'
                              then
                                 Finish := Finish + 2;

                                 if Finish > Last then
                                    Put ("file """);
                                    Put (Dep_Path);
                                    Put_Line (""" has wrong format");

                                    Keep_Dep_File  := True;
                                    Compilation_OK := False;
                                    exit Big_Loop;
                                 end if;

                              else
                                 Finish := Finish + 1;
                              end if;

                           else
                              --  A space that is not preceded by '\'
                              --  indicates the end of the path name.

                              exit when Line (Finish + 1) = ' ';
                              Finish := Finish + 1;
                           end if;
                        end loop;

                        --  Check this source

                        declare
                           Src_Name : constant String :=
                                        Line (Start .. Finish);
                           --  This is a filename encoded by GCC for use as a
                           --  Makefile dependency, with some characters
                           --  escaped for this specific purpose. We are about
                           --  to reuse it in a rewritten dependency file.
                           --  We used to Normalize the path name at this
                           --  point, and this turned out both wrong and
                           --  unnecessary.
                           --  It would be an error to apply Normalize_Pathname
                           --  on it because normalised it can be different
                           --  filename. For example on windows
                           --  c:\path\filename.c escaped became
                           --  c\:path\\filename.c. Normalize_Pathname would
                           --  not understand that it is drive letter at first
                           --  characters and prepend it with current
                           --  directory. We do not need filename to be
                           --  normalised in the GPR rewritten dependency file
                           --  because it is going to be normalised relatively
                           --  to the object directory at reading in
                           --  GPR.Util.Need_To_Compile.Process_Makefile_Deps.

                           Unescaped : constant String :=
                                         OS_Lib.Normalize_Pathname
                                           (Unescape (Src_Name),
                                            Directory => Dir_Name (Dep_Path),
                                            Case_Sensitive => False);
                           Source_2 : Source_Id;
                           Src_TS   : Time_Stamp_Type;

                        begin
                           Source_2 := Source_Paths_Htable.Get
                             (Src_Data.Tree.Source_Paths_HT,
                              Get_Path_Name_Id (Unescaped));
                           Src_TS := File_Stamp (Unescaped);

                           if Src_TS = Empty_Time_Stamp then
                              --  File from dependency list does not exist

                              Put ('"');
                              Put
                                (Get_Name_String
                                   (Src_Data.Id.Path.Display_Name));
                              Put_Line ("""");

                              Put (ASCII.HT & "depends on non-existent """);
                              Put (Unescaped);
                              Put_Line ("""");

                              Put (ASCII.HT & "noted in the """);
                              Put (Dep_Path);
                              Put_Line ("""");

                              Keep_Dep_File  := True;
                              Compilation_OK := False;
                           end if;

                           if Source_2 /= No_Source then
                              --  It is a source of a project

                              if not Project_Extends
                                (Src_Data.Id.Project, Source_2.Project)
                                and then
                                  not Project_Extends
                                    (Source_2.Project, Src_Data.Id.Project)
                              then
                                 --  It is not a source of the same project
                                 --  as the source just compiled. Check if
                                 --  it can be imported.

                                 if not Indirect_Imports then
                                    if Directly_Imports
                                      (Src_Data.Id.Project, Source_2.Project)
                                    then
                                       --  It is a source of a directly
                                       --  imported project. Record its
                                       --  project, for later processing.

                                       Imports.Set (Source_2.Project, True);

                                    else
                                       --  It is a source of a project that
                                       --  is not directly imported. Record
                                       --  the source for later processing.

                                       Included_Sources.Append (Source_2);
                                    end if;
                                 end if;

                                 if not Source_2.In_Interfaces
                                   and then not Source_2.Locally_Removed
                                 then
                                    --  It is not a source in the interfaces
                                    --  of its project. Report an error and
                                    --  invalidate the compilation.

                                    Put ('"');
                                    Put
                                      (Get_Name_String
                                         (Src_Data.Id.Path.Display_Name));
                                    Put (""" cannot import """);
                                    Put (Unescaped);
                                    Put_Line (""":");

                                    Put
                                      ("  it is not part of the "
                                       & "interfaces of its project """);
                                    Put
                                      (Get_Name_String
                                         (Source_2.Project.Display_Name));
                                    Put_Line ("""");

                                    Compilation_OK := False;
                                 end if;
                              end if;
                           end if;

                           Srcs.Append
                             (Src_Record'
                                (F_Len => Src_Name'Length,
                                 File  => Src_Name,
                                 TS    => Src_TS));
                        end;

                        exit Line_Loop when Finish = Last;

                        --  Go get the next source on the line

                        Start := Finish + 1;

                     end loop Name_Loop;
                  end;

                  --  If we are here, we had a continuation character
                  --  \ at the end of the line, so we continue with
                  --  the next line.

                  Get_Line (Dep_File, Name_Buffer, Name_Len);
                  Start  := 1;
                  Finish := 1;
               end loop Line_Loop;
            end loop Big_Loop;

            Close (Dep_File);

            if not Included_Sources.Is_Empty then
               --  Sources in project that are not directly imported
               --  have been found. Check if they may be imported by
               --  other allowed imported sources.

               declare
                  L : Project_List := Src_Data.Id.Project.Imported_Projects;

               begin
                  --  Put in hash table Imports the project trees
                  --  rooted at the projects that are already in
                  --  Imports.

                  while L /= null loop
                     if Imports.Get (L.Project) then
                        Recursive_Import (L.Project);
                     end if;

                     L := L.Next;
                  end loop;

                  --  For all the imported sources from project not
                  --  directly imported, check if their projects are
                  --  in table imports.

                  for Included of Included_Sources loop
                     if not Imports.Get (Included.Project) then
                        --  This source is either directly imported or
                        --  imported from another source that should not be
                        --  imported. Report an error and invalidate the
                        --  compilation.

                        Put ('"');
                        Put (Get_Name_String (Src_Data.Id.Path.Display_Name));
                        Put (""" cannot import """);
                        Put (Get_Name_String (Included.Path.Display_Name));
                        Put_Line (""":");

                        Put ("  """);
                        Put
                          (Get_Name_String (Src_Data.Id.Project.Display_Name));
                        Put (""" does not directly import project """);
                        Put (Get_Name_String (Included.Project.Display_Name));
                        Put_Line ("""");

                        Compilation_OK := False;
                     end if;
                  end loop;
               end;
            end if;
         end if;

         if Compilation_OK and Dep_File_OK then
            Create (Dep_File, Dep_Path);
            Put (Dep_File, Object_Path.all);
            Put (Dep_File, ": ");

            for Src of Srcs loop
               if Was then
                  Put_Line (Dep_File, " \");
               else
                  Was := True;
               end if;

               Put (Dep_File, Src.File);
               Put (Dep_File, " ");
               Put (Dep_File, String (Src.TS));
            end loop;
            Put_Line (Dep_File, "");

            Close (Dep_File);
         end if;

         Free (Object_Path);

         return Compilation_OK;
      end Phase_2_Makefile;

      -----------------
      -- Phase_2_ALI --
      -----------------

      function Phase_2_ALI (Src_Data : Queue.Source_Info) return Boolean is
         Compilation_OK : Boolean := True;
         Text           : Text_Buffer_Ptr :=
                            Read_Library_Info_From_Full
                              (File_Name_Type (Src_Data.Id.Dep_Path),
                               Src_Data.Id.Dep_TS'Access);
         The_ALI        : ALI.ALI_Id := ALI.No_ALI_Id;

         procedure Check_Source (Sfile : File_Name_Type);
         --  Check if source Sfile is in the same project file as the Src_Data
         --  source file. Invalidate the compilation if it is not.

         ------------------
         -- Check_Source --
         ------------------

         procedure Check_Source (Sfile : File_Name_Type) is
            Source_3 : constant Source_Id :=
                         Find_Source
                           (Src_Data.Tree, No_Project, Base_Name => Sfile);

         begin
            if Source_3 = No_Source then
               Put ("source ");
               Put (Get_Name_String (Sfile));
               Put_Line (" is not a source of a project");
               Compilation_OK := False;

            elsif Ultimate_Extending_Project_Of (Source_3.Project) /=
              Ultimate_Extending_Project_Of (Src_Data.Id.Project)
            then
               Put ("sources ");
               Put (Get_Name_String (Source_3.File));
               Put (" and ");
               Put (Get_Name_String (Src_Data.Id.File));
               Put (" belong to different projects: ");
               Put (Get_Name_String (Source_3.Project.Display_Name));
               Put (" and ");
               Put_Line (Get_Name_String (Src_Data.Id.Project.Display_Name));
               Compilation_OK := False;
            end if;
         end Check_Source;

      begin
         if Text /= null then
            --  Read the ALI file but read only the necessary lines

            The_ALI :=
              ALI.Scan_ALI
                (File_Name_Type (Src_Data.Id.Dep_Path),
                 Text,
                 Ignore_ED  => False,
                 Err        => True,
                 Read_Lines => "DW");

            if The_ALI /= ALI.No_ALI_Id then
               Check_Interface_And_Indirect_Imports
                 (The_ALI      => The_ALI,
                  Src_Data     => Src_Data,
                  Success      => Compilation_OK);

               if Opt.No_Split_Units then

                  --  Initialized the list of subunits with the unit name

                  Subunits.Clear;
                  Subunits.Append (Get_Name_String (Src_Data.Id.Unit.Name));

                  --  First check that the spec and the body are in the same
                  --  project.

                  for J in ALI.ALIs.Table (The_ALI).First_Unit ..
                    ALI.ALIs.Table (The_ALI).Last_Unit
                  loop
                     Check_Source (ALI.Units.Table (J).Sfile);
                  end loop;

                  --  Next, check the subunits, if any

                  declare
                     Subunit_Found : Boolean;
                     Already_Found : Boolean;
                     Last          : Positive;
                  begin
                     --  Loop until we don't find new subunits

                     loop
                        Subunit_Found := False;

                        for D in ALI.ALIs.Table (The_ALI).First_Sdep
                          .. ALI.ALIs.Table (The_ALI).Last_Sdep
                        loop
                           if ALI.Sdep.Table (D).Subunit_Name /= No_Name then
                              Get_Name_String
                                (ALI.Sdep.Table (D).Subunit_Name);

                              --  First check if we already found this subunit

                              Already_Found :=
                                Subunits.Contains
                                  (Name_Buffer (1 .. Name_Len));

                              if not Already_Found then
                                 --  Find the name of the parent

                                 Last := Name_Len - 1;
                                 while Last > 1
                                   and then Name_Buffer (Last + 1) /= '.'
                                 loop
                                    Last := Last - 1;
                                 end loop;

                                 if Subunits.Contains
                                   (Name_Buffer (1 .. Last))
                                 then
                                    --  It is a new subunit, add it o the
                                    --  list and check if it is in the right
                                    --  project.

                                    Subunits.Append
                                      (Name_Buffer (1 .. Name_Len));
                                    Subunit_Found := True;
                                    Check_Source (ALI.Sdep.Table (D).Sfile);
                                 end if;
                              end if;
                           end if;
                        end loop;

                        exit when not Subunit_Found;
                     end loop;
                  end;
               end if;

               if Compilation_OK
                 and then
                   (Builder_Data (Src_Data.Tree).Closure_Needed
                    or else Src_Data.Closure)
               then
                  Record_ALI_For (Src_Data, The_ALI);
               end if;
            end if;

            Free (Text);
         end if;

         return Compilation_OK;
      end Phase_2_ALI;

      --------------------------
      -- Set_Options_For_File --
      --------------------------

      procedure Set_Options_For_File (Id : Source_Id) is
         Config                   : Language_Config renames Id.Language.Config;
         Builder_Options_Instance : constant String_Vector_Access :=
                                      Builder_Compiling_Options_HTable.Get
                                        (Id.Language.Name);
         Comp_Opt                 : constant String_Vector_Access :=
                                      Compiling_Options_HTable.Get
                                        (Id.Language.Name);

         List    : Name_List_Index;
         Nam_Nod : Name_Node;
         First   : Boolean;
         Index   : Natural := 0;

      begin
         Compilation_Options.Clear;

         --  1a) The leading required switches

         List := Config.Compiler_Leading_Required_Switches;
         First := True;
         while List /= No_Name_List loop
            Nam_Nod := Project_Tree.Shared.Name_Lists.Table (List);

            if Nam_Nod.Name /= Empty_String then
               Add_Option_Internal_Codepeer
                 (Value   => Get_Name_String (Nam_Nod.Name),
                  To      => Compilation_Options,
                  Display => First or Opt.Verbose_Mode);
               First := False;
            end if;

            List := Nam_Nod.Next;
         end loop;

         --  1b) The switches in CodePeer mode

         if Opt.CodePeer_Mode then
            --  Replace -x ada with -x adascil

            for J in 1 .. Compilation_Options.Last_Index loop
               if Compilation_Options (J).Name = "-x" then
                  Compilation_Options.Replace_Element
                    (J + 1,
                     Option_Type'
                       (Name_Len    => 7,
                        Name        => "adascil",
                        Displayed   => True,
                        Simple_Name => False));
                  Index := J;
                  exit;
               end if;
            end loop;

            if Index = 0 then
               Add_Option
                 (Value       => "-x",
                  To          => Compilation_Options,
                  Display     => True,
                  Simple_Name => False);
               Add_Option
                 (Value       => "adascil",
                  To          => Compilation_Options,
                  Display     => True,
                  Simple_Name => False);
            end if;

            Add_Option
              (Value   => "-gnatcC",
               To      => Compilation_Options,
               Display => True);
         end if;

         --  2) The compilation switches specified in package Builder
         --  for all compilers, following "-cargs", if any.

         for Option of All_Language_Builder_Compiling_Options loop
            Add_Option_Internal_Codepeer
              (Value   => Option,
               To      => Compilation_Options,
               Display => True);
         end loop;

         --  3) The compilation switches specified in package Builder
         --  for the compiler of the language, following
         --  -cargs:<language>.

         if Builder_Options_Instance /= null then
            for Option of Builder_Options_Instance.all loop
               Add_Option_Internal_Codepeer
                 (Value   => Option,
                  To      => Compilation_Options,
                  Display => True);
            end loop;
         end if;

         --  4) Compiler'Switches(<source file name>), if it is
         --  defined, otherwise Compiler'Switches (<language name>),
         --  if defined.

         Add_Compilation_Switches (Id);

         --  5) The switches specified on the gprbuild command line
         --  for all compilers, following "-cargs", if any.

         for Option of All_Language_Compiling_Options loop
            Add_Option_Internal_Codepeer
              (Value   => Option,
               To      => Compilation_Options,
               Display => True);
         end loop;

         --  6) The switches specified on the gprbuild command line
         --  for the compiler of the language, following
         --  -cargs:<language>.

         if Comp_Opt /= null then
            for Opt of Comp_Opt.all loop
               Add_Option_Internal_Codepeer
                 (Value   => Opt,
                  To      => Compilation_Options,
                  Display => True);
            end loop;
         end if;

         --  7) The PIC option if it exists, for shared and "static-pic"
         --     libraries.

         if Id.Project.Library
           and then Id.Project.Library_Kind /= Static
         then
            List := Config.Compilation_PIC_Option;
            while List /= No_Name_List loop
               Nam_Nod := Project_Tree.Shared.Name_Lists.Table (List);
               Add_Option_Internal_Codepeer
                 (Value   => Get_Name_String (Nam_Nod.Name),
                  To      => Compilation_Options,
                  Display => True);
               List := Nam_Nod.Next;
            end loop;
         end if;
      end Set_Options_For_File;

      -------------------------
      -- Check_Switches_File --
      -------------------------

      function Check_Switches_File (Id : Source_Id) return Boolean is

         File : Text_IO.File_Type;

         File_Content     : String_Vectors.Vector;
         Expected_Content : String_Vectors.Vector;

         function Assert_Line (Current : String) return Boolean;
         --  Return False if Current is not the next line in the switches file

         -----------------
         -- Assert_Line --
         -----------------

         function Assert_Line (Current : String) return Boolean is
            Line : String (1 .. 1_000);
            Last : Natural;
         begin
            if End_Of_File (File) then
               if Opt.Verbosity_Level > Opt.Low then
                  Put_Line ("    -> switches file has fewer switches");
               end if;

               Close (File);
               return False;
            end if;

            Get_Line (File, Line, Last);

            if Line (1 .. Last) /= Current then
               if Opt.Verbosity_Level > Opt.Low then
                  Put_Line ("    -> switches file '"
                              & Get_Name_String (Id.Switches_Path)
                              & "' has different line");
                  Put_Line ("       " & Line (1 .. Last));
                  Put_Line ("       " & Current);
               end if;

               Close (File);
               return False;
            end if;
            return True;
         end Assert_Line;

         List    : Name_List_Index;
         Nam_Nod : Name_Node;

         use GPR.Debug;

      begin
         if Opt.Verbosity_Level > Opt.Low and then Debug.Debug_Flag_S then
            Expected_Content.Append (String (Id.Object_TS));

            for Opt of Compilation_Options loop
               Expected_Content.Append (Opt.Name);
            end loop;

            List := Id.Language.Config.Compiler_Trailing_Required_Switches;

            while List /= No_Name_List loop
               Nam_Nod := Project_Tree.Shared.Name_Lists.Table (List);
               Expected_Content.Append (Get_Name_String (Nam_Nod.Name));
               List := Nam_Nod.Next;
            end loop;
         end if;

         Open (File, In_File, Get_Name_String (Id.Switches_Path));

         if Opt.Verbosity_Level > Opt.Low and then Debug.Debug_Flag_S then
            declare
               Line : String (1 .. 1_000);
               Last : Natural;
            begin
               while not End_Of_File (File) loop
                  Get_Line (File, Line, Last);
                  File_Content.Append (Line (1 .. Last));
               end loop;
            end;
            Reset (File);
            Put_Line ("       expected .cswi file content:");
            for S of Expected_Content loop
               Put_Line ("          " & S);
            end loop;
            Put_Line ("       actual .cswi file content:");
            for S of File_Content loop
               Put_Line ("          " & S);
            end loop;
         end if;

         if not Assert_Line (String (Id.Object_TS)) then
            return True;
         end if;

         for Opt of Compilation_Options loop
            if not Assert_Line (Opt.Name) then
               return True;
            end if;
         end loop;

         List := Id.Language.Config.Compiler_Trailing_Required_Switches;

         while List /= No_Name_List loop
            Nam_Nod := Project_Tree.Shared.Name_Lists.Table (List);

            if not Assert_Line (Get_Name_String (Nam_Nod.Name)) then
               return True;
            end if;

            List := Nam_Nod.Next;
         end loop;

         if not End_Of_File (File) then
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line ("    -> switches file has more switches");
            end if;

            Close (File);
            return True;
         end if;

         Close (File);
         return False;

      exception
         when others =>
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line ("    -> no switches file");
            end if;
            return True;
      end Check_Switches_File;

      ------------------------
      -- Update_Object_Path --
      ------------------------

      procedure Update_Object_Path
        (Id : Source_Id; Source_Project : Project_Id) is
      begin
         Id.Object_Project := Source_Project;

         if Id.Object_Project /= Id.Project then
            if Id.Object /= No_File then
               Get_Name_String
                 (Id.Object_Project.Object_Directory.Display_Name);
               Get_Name_String_And_Append (Id.Object);
               Id.Object_Path := Name_Find;
            end if;

            if Id.Dep_Name /= No_File then
               Get_Name_String
                 (Id.Object_Project.Object_Directory.Display_Name);
               Get_Name_String_And_Append (Id.Dep_Name);
               Id.Dep_Path := Name_Find;
            end if;

            if Id.Switches /= No_File then
               Get_Name_String
                 (Id.Object_Project.Object_Directory.Display_Name);
               Get_Name_String_And_Append (Id.Switches);
               Id.Switches_Path := Name_Find;
            end if;
         end if;
      end Update_Object_Path;

      ----------------------------
      -- Add_Dependency_Options --
      ----------------------------

      procedure Add_Dependency_Options (Id : Source_Id) is
         List : Name_List_Index := Id.Language.Config.Dependency_Option;
         Node : Name_Node;
      begin
         if Id.Language.Config.Dependency_Kind /= None then
            while List /= No_Name_List loop
               Node := Project_Tree.Shared.Name_Lists.Table (List);
               List := Node.Next;

               if List = No_Name_List then
                  Add_Option
                    (Value   => Get_Name_String (Node.Name)
                     & Get_Name_String (Id.Dep_Name),
                     To      => Compilation_Options,
                     Display => Opt.Verbose_Mode);
               else
                  Add_Option
                    (Value   => Node.Name,
                     To      => Compilation_Options,
                     Display => Opt.Verbose_Mode);
               end if;
            end loop;
         end if;
      end Add_Dependency_Options;

      ------------------------------
      -- Add_Object_File_Switches --
      ------------------------------

      procedure Add_Object_File_Switches (Id : Source_Id) is
         List : Name_List_Index := Id.Language.Config.Object_File_Switches;
         Node : Name_Node;
      begin
         if List /= No_Name_List then
            loop
               Node := Project_Tree.Shared.Name_Lists.Table (List);
               exit when Node.Next = No_Name_List;

               Add_Option
                 (Node.Name,
                  To      => Compilation_Options,
                  Display => Opt.Verbose_Mode or else Id.Index /= 0);
               List := Node.Next;
            end loop;

            Get_Name_String (Node.Name);
            Get_Name_String_And_Append (Id.Object);

            Add_Option
              (Name_Buffer (1 .. Name_Len),
               To      => Compilation_Options,
               Display => Opt.Verbose_Mode or else Id.Index /= 0);

         --  Always specify object-file for a multi-unit source file

         elsif Id.Index /= 0 then
            Add_Option
              ("-o",
               To      => Compilation_Options,
               Display => True);
            Add_Option
              (Get_Name_String (Id.Object),
               To      => Compilation_Options,
               Display => True);
         end if;
      end Add_Object_File_Switches;

      ------------------------------
      -- Add_Object_Path_Switches --
      ------------------------------

      procedure Add_Object_Path_Switches (Id : Source_Id) is
         List : Name_List_Index := Id.Language.Config.Object_Path_Switches;
         Node : Name_Node;

      begin
         if List /= No_Name_List then
            if Id.Project.Object_Path_File = No_Path then
               Create_Object_Path_File (Id.Project, Project_Tree.Shared);
            end if;

            while List /= No_Name_List loop
               Node := Project_Tree.Shared.Name_Lists.Table (List);
               exit when Node.Next = No_Name_List;

               Add_Option
                 (Node.Name,
                  To      => Compilation_Options,
                  Display => Opt.Verbose_Mode);
               List := Node.Next;
            end loop;

            Get_Name_String (Node.Name);
            Get_Name_String_And_Append (Id.Project.Object_Path_File);

            Add_Option
              (Name_Buffer (1 .. Name_Len),
               To      => Compilation_Options,
               Display => Opt.Verbose_Mode);
         end if;
      end Add_Object_Path_Switches;

      ----------------------
      -- Get_Config_Paths --
      ----------------------

      procedure Get_Config_Paths
        (Id             : Source_Id;
         Source_Project : Project_Id)
      is
         Config : constant Language_Config := Id.Language.Config;

         procedure Add_Config_File (Project : Project_Id; Pkg, Attr : Name_Id);

         procedure Add_Config_File (Project : Project_Id; Pkg, Attr : Name_Id)
         is
            Config_File_Path : constant Path_Information :=
                                 Config_File_For
                                   (Project        => Project,
                                    Package_Name   => Pkg,
                                    Attribute_Name => Attr,
                                    Language       => Id.Language.Name);
         begin
            if Config_File_Path /= No_Path_Information
              and then not Cmd_Line_Adc_Files.Contains
                             (Name_Id (Config_File_Path.Name))
            then
               Last_Config_Path := Last_Config_Path + 1;
               The_Config_Paths (Last_Config_Path) := Config_File_Path;
            end if;
         end Add_Config_File;

      begin
         Last_Config_Path := 0;

         if Config.Config_File_Switches /= No_Name_List
           and then (Config.Config_Body /= No_Name
                     or else Config.Config_Body_Index /= No_Name
                     or else Config.Config_Body_Pattern /= No_Name
                     or else Config.Config_Spec /= No_Name
                     or else Config.Config_Spec_Index /= No_Name
                     or else Config.Config_Spec_Pattern /= No_Name)
           and then not Config.Config_File_Unique
         then
            Add_Config_File
              (Main_Project, Name_Builder, Name_Global_Config_File);
            Add_Config_File
              (Source_Project, Name_Compiler, Name_Local_Config_File);
         end if;

         for CF in Cmd_Line_Adc_Files.Iterate loop
            Last_Config_Path := Last_Config_Path + 1;
            The_Config_Paths (Last_Config_Path) :=
              (Name         => Path_Name_Type (Name_Id_Maps.Key (CF)),
               Display_Name => Path_Name_Type (Name_Id_Maps.Element (CF)));
         end loop;
      end Get_Config_Paths;

      ------------------------------
      -- Add_Config_File_Switches --
      ------------------------------

      procedure Add_Config_File_Switches
        (Id             : Source_Id;
         Source_Project : Project_Id)
      is
         Config           : constant Language_Config := Id.Language.Config;
         --  Config_File_Path : Path_Name_Type;
      begin
         if Config.Config_File_Switches /= No_Name_List
           and then (Config.Config_Body /= No_Name
                     or else Config.Config_Body_Index /= No_Name
                     or else Config.Config_Body_Pattern /= No_Name
                     or else Config.Config_Spec /= No_Name
                     or else Config.Config_Spec_Index /= No_Name
                     or else Config.Config_Spec_Pattern /= No_Name)
         then
            Create_Config_File
              (For_Project => Source_Project,
               Config      => Config,
               Language    => Id.Language.Name);

            if Source_Project.Config_File_Name /= No_Path then
               Add_Config_File_Switch
                 (Config    => Config,
                  Path_Name => Source_Project.Config_File_Name);
            end if;

            for J in 1 .. Last_Config_Path loop
               Add_Config_File_Switch
                 (Config    => Config,
                  Path_Name => The_Config_Paths (J).Display_Name);
            end loop;
         end if;
      end Add_Config_File_Switches;

      -------------------------------
      -- Add_Mapping_File_Switches --
      -------------------------------

      function Add_Mapping_File_Switches
        (Source         : Queue.Source_Info;
         Source_Project : Project_Id) return Path_Name_Type
      is
         List              : Name_List_Index :=
                               Source.Id.Language.Config.Mapping_File_Switches;
         Node              : Name_Node;
         Mapping_File_Path : Path_Name_Type;
      begin
         if List /= No_Name_List then
            --  Check if there is a temporary mapping file we can use

            Mapping_File_Path := Mapping_Files_Htable.Get_First
              (Source.Id.Language.Mapping_Files);

            if Mapping_File_Path /= No_Path then
               --  Reuse this temporary mapping file and remove its
               --  name from the HTable so that it is not reused
               --  before the compilation terminates.

               Mapping_Files_Htable.Remove
                 (Source.Id.Language.Mapping_Files, Mapping_File_Path);

            else
               --  Create a new temporary mapping file, as there are
               --  none that can be reused.

               GPR.Env.Create_Mapping_File
                 (Project  => Source_Project,
                  Language => Source.Id.Language.Name,
                  In_Tree  => Source.Tree,
                  Name     => Mapping_File_Path);
            end if;

            while List /= No_Name_List loop
               Node := Source.Tree.Shared.Name_Lists.Table (List);
               List := Node.Next;

               if List /= No_Name_List then
                  Add_Option
                    (Value   => Node.Name,
                     To      => Compilation_Options,
                     Display => Opt.Verbose_Mode);

               else
                  Get_Name_String (Node.Name);
                  Get_Name_String_And_Append (Mapping_File_Path);
                  Add_Option
                    (Name_Buffer (1 .. Name_Len),
                     To      => Compilation_Options,
                     Display => Opt.Verbose_Mode);
               end if;
            end loop;

            return Mapping_File_Path;

         else
            return No_Path;
         end if;
      end Add_Mapping_File_Switches;

      -----------------------------
      -- Add_Multi_Unit_Switches --
      -----------------------------

      procedure Add_Multi_Unit_Switches (Id : Source_Id) is
         List : Name_List_Index := Id.Language.Config.Multi_Unit_Switches;
      begin
         if Id.Index /= 0
           and then List /= No_Name_List
         then
            declare
               Index_Img : constant String := Id.Index'Img;
               Node      : Name_Node;

            begin
               loop
                  Node := Project_Tree.Shared.Name_Lists.Table (List);
                  exit when Node.Next = No_Name_List;

                  Add_Option
                    (Node.Name,
                     To      => Compilation_Options,
                     Display => True);
                  List := Node.Next;
               end loop;

               Get_Name_String (Node.Name);
               Add_Str_To_Name_Buffer (Index_Img (2 .. Index_Img'Last));
               Add_Option
                 (Name_Buffer (1 .. Name_Len),
                  To      => Compilation_Options,
                  Display => True);
            end;
         end if;
      end Add_Multi_Unit_Switches;

      ---------------------------
      -- Add_Trailing_Switches --
      ---------------------------

      procedure Add_Trailing_Switches (Id : Source_Id) is
         List : Name_List_Index :=
                  Id.Language.Config.Compiler_Trailing_Required_Switches;
         Node : Name_Node;
      begin
         while List /= No_Name_List loop
            Node := Project_Tree.Shared.Name_Lists.Table (List);
            Add_Option
              (Node.Name,
               To      => Compilation_Options,
               Display => Opt.Verbose_Mode);
            List := Node.Next;
         end loop;
      end Add_Trailing_Switches;

      ---------------------------------
      -- Add_Name_Of_Source_Switches --
      ---------------------------------

      procedure Add_Name_Of_Source_Switches (Id : Source_Id) is
         List : Name_List_Index := Id.Language.Config.Source_File_Switches;
         Node : Name_Node;
      begin
         --  Add any source file prefix

         if List /= No_Name_List then
            loop
               Node := Project_Tree.Shared.Name_Lists.Table (List);
               exit when Node.Next = No_Name_List;

               Add_Option
                 (Node.Name,
                  To      => Compilation_Options,
                  Display => Opt.Verbose_Mode or else Id.Index /= 0);
               List := Node.Next;
            end loop;
         end if;

         --  Then handle the source file

         Add_Option
           (Get_Name_String_Or_Null (Node.Name)
            & Get_Name_String (Id.Path.Display_Name),
            To          => Compilation_Options,
            Display     => True,
            Simple_Name => not Opt.Verbose_Mode);
      end Add_Name_Of_Source_Switches;

      ---------------------------------
      -- Spawn_Compiler_And_Register --
      ---------------------------------

      procedure Spawn_Compiler_And_Register
        (Source                 : Queue.Source_Info;
         Source_Project         : Project_Id;
         Compiler_Path          : String;
         Mapping_File_Path      : Path_Name_Type;
         Last_Switches_For_File : Integer)
      is

         procedure Add_Process
           (Process        : GPR.Compilation.Id;
            Source         : Queue.Source_Info;
            Source_Project : Project_Id;
            Mapping_File   : Path_Name_Type;
            Purpose        : Process_Purpose;
            Options        : String_Vectors.Vector);
         --  Add compilation process and indicate that the object directory is
         --  busy.

         procedure Escape_Options (Options : in out Options_Data);
         --  On all platforms, escapes the characters '\', ' ' and '"' with
         --  character '\' before them.

         -----------------
         -- Add_Process --
         -----------------

         procedure Add_Process
           (Process        : GPR.Compilation.Id;
            Source         : Queue.Source_Info;
            Source_Project : Project_Id;
            Mapping_File   : Path_Name_Type;
            Purpose        : Process_Purpose;
            Options        : String_Vectors.Vector) is
         begin
            Compilation_Htable.Set
              (Process,
               (Process, Source, Source_Project,
                Mapping_File, Purpose, Options));
            Outstanding_Compiles := Outstanding_Compiles + 1;

            Queue.Set_Obj_Dir_Busy (Source.Id.Project.Object_Directory.Name);
         end Add_Process;

         --------------------
         -- Escape_Options --
         --------------------

         procedure Escape_Options (Options : in out Options_Data)
         is
            Last : constant Natural := Options.Last_Index;
         begin
            for J in 1 .. Last loop
               declare
                  Opt  : constant String := Options (J).Name;
                  Nopt : constant String := Escape_Path (Opt);
               begin
                  if Nopt'Length > Opt'Length then
                     Options.Replace_Element
                       (J,
                        Option_Type'
                          (Name_Len    => Nopt'Length,
                           Name        => Nopt,
                           Displayed   => Options.Element (J).Displayed,
                           Simple_Name => Options.Element (J).Simple_Name));
                  end if;
               end;
            end loop;
         end Escape_Options;

         ------------------
         -- Get_Language --
         ------------------

         function Get_Language return String is
           (if Source.Id.Language /= null
            then Get_Name_String (Source.Id.Language.Name)
            else "");

         Process       : GPR.Compilation.Id;
         Response_File : Path_Name_Type := No_Path;

      --  Start of processing of Spawn_Compiler_And_Register

      begin

         if Opt.Use_GNU_Make_Jobserver
           and then not Preorder_Token
         then
            return;
         else
            if not Opt.Quiet_Output then
               Name_Len := 0;

               if Opt.Verbose_Mode then
                  Add_Str_To_Name_Buffer (Compiler_Path);

                  for Opt of Compilation_Options loop
                     Add_Str_To_Name_Buffer (" ");

                     if Opt.Simple_Name then
                        Add_Str_To_Name_Buffer (Base_Name (Opt.Name));

                     else
                        Add_Str_To_Name_Buffer (Opt.Name);
                     end if;
                  end loop;

                  Put_Line (Name_Buffer (1 .. Name_Len));

               else
                  Display
                    (Section  => GPR.Compile,
                     Command  =>
                       Get_Name_String (Source.Id.Language.Display_Name),
                     Argument => Get_Name_String (Source.Id.File));
               end if;
            end if;

            if Source_Project.Config.Max_Command_Line_Length > 0 and then
              Source.Id.Language.Config.Resp_File_Format = GCC_GNU
            then
               declare
                  Arg_Length : Natural := 0;
               begin
                  for Opt of Compilation_Options loop
                     Arg_Length :=
                       Arg_Length + 1 + Opt.Name'Length;
                  end loop;

                  if Arg_Length
                    > Source_Project.Config.Max_Command_Line_Length
                  then
                     declare
                        use GPR.Tempdir;
                        FD             : File_Descriptor;
                        Status         : Integer;
                        Closing_Status : Boolean;

                     begin
                        --  Escape the following characters in the options:
                        --  '\', ' ' and '"'.

                        Escape_Options (Compilation_Options);

                        Create_Temp_File (FD, Response_File);
                        Record_Temp_File
                          (Shared => Source.Tree.Shared,
                           Path   => Response_File);

                        Option_Loop : for Opt of Compilation_Options loop
                           Status :=
                             Write
                               (FD,
                                Opt.Name (1)'Address,
                                Opt.Name'Length);

                           if Status /= Opt.Name'Length
                           then
                              Put_Line
                                ("Could not write option """ &
                                   Opt.Name &
                                   """ in response file """ &
                                   Get_Name_String (Response_File) &
                                   """");
                              Response_File := No_Path;
                              exit Option_Loop;
                           end if;

                           Status := Write (FD, ASCII.LF'Address, 1);
                        end loop Option_Loop;

                        Close (FD, Closing_Status);

                        if not Closing_Status and then Response_File /= No_Path
                        then
                           Put_Line
                             ("Could not close response file """ &
                                Get_Name_String (Response_File) &
                                """");
                           Response_File := No_Path;
                        end if;
                     end;

                     if Opt.Verbosity_Level > Opt.Low and then
                       Response_File /= No_Path
                     then
                        Put_Line ("using a response file");
                     end if;
                  end if;
               end;
            end if;

            Process := Run
              (Compiler_Path,
               Options_List (Compilation_Options),
               Source_Project,
               Source        => Get_Name_String (Source.Id.File),
               Language      => Get_Language,
               Dep_Name      => (if Source.Id.Dep_Name = No_File
                                 then ""
                                 else Get_Name_String (Source.Id.Dep_Name)),
               Obj_Name      => (if Source.Id.Object = No_File
                                 then ""
                                 else Get_Name_String (Source.Id.Object)),
               Response_File => Response_File);

            if Last_Switches_For_File >= 0 then
               while Compilation_Options.Last_Index > Last_Switches_For_File
               loop
                  Compilation_Options.Delete_Last;
               end loop;

               Add_Trailing_Switches (Source.Id);
            end if;

            Add_Process
              (Process        => Process,
               Source         => Source,
               Source_Project => Source_Project,
               Mapping_File   => Mapping_File_Path,
               Purpose        => Compilation,
               Options        => Options_List (Compilation_Options));

            if Opt.Use_GNU_Make_Jobserver then
               Register_Token_Id (Id => Process);
            end if;
         end if;
      end Spawn_Compiler_And_Register;

      ------------------------------
      -- Get_Compatible_Languages --
      ------------------------------

      function Get_Compatible_Languages
        (Lang : Language_Ptr) return Name_Ids
      is
         NL        : Name_List_Index :=
                       Lang.Config.Include_Compatible_Languages;
         Languages : Name_Ids
           (1 .. 1 + Length (Project_Tree.Shared.Name_Lists, NL));
         Index     : Positive := 1;
      begin
         Languages (Index) := Lang.Name;

         while NL /= No_Name_List loop
            Index := Index + 1;
            Languages (Index) :=
              Project_Tree.Shared.Name_Lists.Table (NL).Name;
            NL := Project_Tree.Shared.Name_Lists.Table (NL).Next;
         end loop;

         return Languages;
      end Get_Compatible_Languages;

      -------------------------------
      -- Prepare_Include_Path_File --
      -------------------------------

      procedure Prepare_Include_Path_File
        (Data    : out Local_Project_Data;
         Project : Project_Id;
         Lang    : Language_Ptr)
      is
         FD     : File_Descriptor;
         Status : Boolean;
      begin
         Get_Directories
           (Project_Tree => Project_Tree,
            For_Project  => Project,
            Activity     => Compilation,
            Languages    => Get_Compatible_Languages (Lang));

         GPR.Env.Create_New_Path_File
           (Shared    => Project_Tree.Shared,
            Path_FD   => FD,
            Path_Name => Data.Include_Path_File);

         if FD = Invalid_FD then
            Fail_Program
              (Project_Tree, "could not create temporary path file");
         end if;

         for Index in 1 .. Directories.Last loop
            Get_Name_String (Directories.Table (Index));
            Name_Len := Name_Len + 1;
            Name_Buffer (Name_Len) := ASCII.LF;
            if Write (FD, Name_Buffer (1)'Address, Name_Len) /= Name_Len then
               Fail_Program
                 (Project_Tree,
                  "disk full when writing include path file");
            end if;
         end loop;

         Close (FD, Status);

         if not Status then
            Fail_Program
              (Project_Tree,
               "disk full when writing include path file");
         end if;
      end Prepare_Include_Path_File;

      ------------------------------------
      -- Prepare_Imported_Dirs_Switches --
      ------------------------------------

      procedure Prepare_Imported_Dirs_Switches
        (Data    : out Local_Project_Data;
         Project : Project_Id;
         Lang    : Language_Ptr)
      is
         Len       : constant Natural :=
                       Length
                         (Project_Tree.Shared.Name_Lists,
                          Lang.Config.Include_Option);
--           Host_Path : OS_Lib.String_Access;
         Last      : Natural := 0;
         List      : Name_List_Index;
         Nam       : Name_Node;
      begin
         Get_Directories
           (Project_Tree => Project_Tree,
            For_Project  => Project,
            Activity     => Compilation,
            Languages    => Get_Compatible_Languages (Lang));

         Free (Data.Imported_Dirs_Switches);
         Data.Imported_Dirs_Switches :=
           new String_List (1 .. Directories.Last * Len);

         for Index in 1 .. Directories.Last loop
            List := Lang.Config.Include_Option;
            while List /= No_Name_List loop
               Nam := Project_Tree.Shared.Name_Lists.Table (List);
               exit when Nam.Next = No_Name_List;
               Last := Last + 1;
               Data.Imported_Dirs_Switches (Last) :=
                 new String'(Get_Name_String (Nam.Name));
               List := Nam.Next;
            end loop;

            Get_Name_String (Directories.Table (Index));

            while Name_Len > 1
              and then (Name_Buffer (Name_Len) = Directory_Separator
                        or else Name_Buffer (Name_Len) = '/')
            loop
               Name_Len := Name_Len - 1;
            end loop;

            Last := Last + 1;

            --  Concatenate the last switch and the path in a single option

            Data.Imported_Dirs_Switches (Last) := new String'
              (Get_Name_String (Nam.Name) & Name_Buffer (1 .. Name_Len));
         end loop;
      end Prepare_Imported_Dirs_Switches;

      ------------------------------
      -- Set_Env_For_Include_Dirs --
      ------------------------------

      procedure Set_Env_For_Include_Dirs
        (Id : Source_Id; Source_Project : Project_Id)
      is
         Current_Project      : Project_Id   := No_Project;
         Current_Language_Ind : Language_Ptr := No_Language_Index;
         --  The project for which the include path environment has been set
         --  last, to avoid computing it several times.

         Data : Local_Project_Data :=
                  Local_Projects_HT.Get (Local_Projects, Id.Object_Project);
      begin
         --  Prepare (if not already done) the data for Project/Lang.
         --  All files for a given language are processed sequentially, before
         --  we switch to the next language, so we are only preparing once per
         --  language here.

         if Data.Include_Language /= Id.Language then
            Free (Data.Include_Path);
            Free (Data.Imported_Dirs_Switches);
            Data := No_Local_Project_Data;

            if Id.Language.Config.Include_Option /= No_Name_List then
               Prepare_Imported_Dirs_Switches
                 (Data, Id.Object_Project, Id.Language);

            elsif
              Id.Language.Config.Include_Switches_Via_Spec /= No_Name_List
            then
               declare
                  Include_Switches_Spec : File_Descriptor := Invalid_FD;
                  Switches_File_Name    : Path_Name_Type;
                  Switches_File         : File_Descriptor := Invalid_FD;
                  Status                : Boolean := False;

                  Compiler : OS_Lib.String_Access;
                  Switch   : OS_Lib.String_Access;

                  List : Name_List_Index :=
                          Id.Language.Config.Include_Switches_Via_Spec;
                  Elem : Name_Node;
               begin
                  Elem := Project_Tree.Shared.Name_Lists.Table (List);
                  Compiler := new String'(Get_Name_String (Elem.Name));
                  List := Elem.Next;
                  Elem := Project_Tree.Shared.Name_Lists.Table (List);
                  Switch := new String'(Get_Name_String (Elem.Name));

                  Get_Directories
                    (Project_Tree => Project_Tree,
                     For_Project  => Id.Object_Project,
                     Activity     => Compilation,
                     Languages    => Get_Compatible_Languages (Id.Language));

                  GPR.Env.Create_Temp_File
                    (Project_Tree.Shared,
                     Switches_File,
                     Switches_File_Name,
                     "include switches");

                  for Index in 1 .. Directories.Last loop
                     Set_Name_Buffer (Switch.all);
                     Add_Str_To_Name_Buffer
                       (Escape_Path
                          (Get_Name_String (Directories.Table (Index))));
                     Name_Len := Name_Len + 1;
                     Name_Buffer (Name_Len) := ASCII.LF;

                     if Write
                       (Switches_File, Name_Buffer (1)'Address, Name_Len)
                         /= Name_Len
                     then
                        Fail_Program
                          (Project_Tree,
                           "disk full when writing include switches file");
                     end if;
                  end loop;

                  Close (Switches_File, Status);

                  if not Status then
                     Fail_Program
                       (Project_Tree,
                        "disk full when writing include switches file");
                  end if;

                  GPR.Env.Create_Temp_File
                    (Project_Tree.Shared,
                     Include_Switches_Spec,
                     Data.Include_Switches_Spec_File,
                     "include switches spec");

                  Name_Len := 1;
                  Name_Buffer (1) := '*';
                  Add_Str_To_Name_Buffer (Compiler.all);
                  Name_Len := Name_Len + 1;
                  Name_Buffer (Name_Len) := ':';
                  Name_Len := Name_Len + 1;
                  Name_Buffer (Name_Len) := ASCII.LF;

                  if Write
                    (Include_Switches_Spec,
                     Name_Buffer (1)'Address, Name_Len) /= Name_Len
                  then
                     Fail_Program
                       (Project_Tree,
                        "disk full when writing include switches spec file");
                  end if;

                  Set_Name_Buffer ("+ @");
                  Add_Str_To_Name_Buffer
                    (Escape_Path (Get_Name_String (Switches_File_Name)));
                  Name_Len := Name_Len + 1;
                  Name_Buffer (Name_Len) := ASCII.LF;

                  if Write
                    (Include_Switches_Spec,
                     Name_Buffer (1)'Address, Name_Len) /= Name_Len
                  then
                     Fail_Program
                       (Project_Tree,
                        "disk full when writing include switches spec file");
                  end if;

                  Close (Include_Switches_Spec, Status);

                  if not Status then
                     Fail_Program
                       (Project_Tree,
                        "disk full when writing include switches spec file");
                  end if;

                  Free (Compiler);
                  Free (Switch);

                  declare
                     Path : constant String :=
                              Get_Name_String
                                (Data.Include_Switches_Spec_File);
                  begin
                     Data.Imported_Dirs_Switches :=
                       new String_List'
                         (1 => new String'("-specs=" & Path));
                  end;
               end;

            elsif Id.Language.Config.Include_Path_File /= No_Name then
               if Id.Language.Config.Mapping_File_Switches = No_Name_List
                 or else Opt.Use_Include_Path_File
               then
                  Prepare_Include_Path_File
                    (Data, Id.Object_Project, Id.Language);
               end if;

            elsif Id.Language.Config.Include_Path /= No_Name then
               Get_Directories
                 (Project_Tree => Project_Tree,
                  For_Project  => Id.Object_Project,
                  Activity     => Compilation,
                  Languages    => Get_Compatible_Languages (Id.Language));
               Data.Include_Path := Create_Path_From_Dirs;
            end if;

            Data.Include_Language := Id.Language;

            Local_Projects_HT.Set (Local_Projects, Id.Object_Project, Data);
         end if;

         --  Reset environment variables if they have changed

         if Id.Object_Project /= Current_Project
           or else Id.Language /= Current_Language_Ind
         then
            Current_Project      := Id.Object_Project;
            Current_Language_Ind := Id.Language;

            if Data.Include_Path_File /= No_Path then
               Setenv (Get_Name_String (Id.Language.Config.Include_Path_File),
                       Get_Name_String (Data.Include_Path_File));

            elsif Data.Include_Path /= null then
               GPR.Compilation.Process.Record_Environment
                 (Source_Project,
                  Id.Language.Name,
                  Get_Name_String (Id.Language.Config.Include_Path),
                  Data.Include_Path.all);

               if Opt.Verbosity_Level > Opt.Low then
                  Put
                    (Get_Name_String (Id.Language.Config.Include_Path));
                  Put (" = ");
                  Put_Line (Data.Include_Path.all);
               end if;
            end if;
         end if;

         --  But always set the switches

         if Data.Imported_Dirs_Switches /= null then
            for J in Data.Imported_Dirs_Switches'Range loop
               if Data.Imported_Dirs_Switches (J)'Length > 0 then
                  Add_Option
                    (Value   => Data.Imported_Dirs_Switches (J).all,
                     To      => Compilation_Options,
                     Display => Opt.Verbose_Mode);
               end if;
            end loop;
         end if;
      end Set_Env_For_Include_Dirs;

      -----------------------------
      -- Process_Project_Phase_1 --
      -----------------------------

      procedure Process_Project_Phase_1 (Source : Queue.Source_Info) is
         Id                     : constant Source_Id := Source.Id;
         Project_Tree           : constant Project_Tree_Ref := Source.Tree;
         Source_Project         : constant Project_Id :=
                                    Ultimate_Extending_Project_Of (Id.Project);
         Dummy                  : Boolean;
         Compilation_Needed     : Boolean := True;
         Last_Switches_For_File : Integer;
         Mapping_File           : Path_Name_Type;
         The_ALI                : ALI.ALI_Id;
         Compiler               : OS_Lib.String_Access;

      begin
         Get_Config_Paths (Id, Source_Project);

         if Always_Compile or else not Source_Project.Externally_Built then
            Need_To_Compile
              (Source         => Id,
               Tree           => Source.Tree,
               In_Project     => Source_Project,
               Conf_Paths     => The_Config_Paths (1 .. Last_Config_Path),
               Must_Compile   => Compilation_Needed,
               The_ALI        => The_ALI,
               Object_Check   => Object_Checked,
               Always_Compile => Always_Compile);

            if Total_Errors_Detected > 0 then
               Compilation_Phase_Failed
                 (Source.Tree, No_Message => Opt.No_Exit_Message);
            end if;

            if The_ALI /= ALI.No_ALI_Id then
               declare
                  Success : Boolean := True;
               begin
                  Check_Interface_And_Indirect_Imports
                    (The_ALI  => The_ALI,
                     Src_Data => Source,
                     Success  => Success);

                  if not Success then
                     Compilation_Phase_Failed
                       (Source.Tree,
                        (if Exit_Code = E_Success then E_Fatal else Exit_Code),
                        No_Message => Opt.No_Exit_Message);
                  end if;
               end;
            end if;

            if Compilation_Needed and then Opt.Keep_Going then
               --  When in Keep_Going mode first check that we did not already
               --  tried to compile this source as part of another import of
               --  the corresponding project file.

               if Bad_Compilations.Contains (Id) then
                  Compilation_Needed := False;
               end if;
            end if;

            if Compilation_Needed or else Opt.Check_Switches then
               Set_Options_For_File (Id);

               if Opt.Check_Switches and then not Compilation_Needed then
                  Compilation_Needed := Check_Switches_File (Id);
               end if;
            end if;

            if Compilation_Needed then
               --  If Distributed_Mode activated, parse Remote package to
               --  register and initialize the slaves.

               if Distributed_Mode and then not Slave_Initialized then
                  begin
                     GPR.Compilation.Slave.Register_Remote_Slaves
                       (Project_Tree, Main_Project);
                     Slave_Initialized := True;
                  exception
                     when E : Constraint_Error =>
                        Fail_Program (Project_Tree, Exception_Information (E));
                  end;
               end if;

               Update_Object_Path (Id, Source_Project);
               Change_To_Object_Directory
                 (Source_Project, Must_Be_Writable => True);

               --  Record the last recorded option index, to be able to
               --  write the switches file later.

               if Id.Language.Config.Object_Generated then
                  Last_Switches_For_File := Compilation_Options.Last_Index;
               else
                  Last_Switches_For_File := -1;
               end if;

               Add_Dependency_Options (Id);
               Set_Env_For_Include_Dirs (Id, Source_Project);
               Add_Config_File_Switches (Id, Source_Project);
               Mapping_File := Add_Mapping_File_Switches
                 (Source, Source_Project);
               Add_Trailing_Switches (Id);
               Add_Name_Of_Source_Switches (Id);
               Add_Object_File_Switches (Id);
               Add_Multi_Unit_Switches (Id);
               Add_Object_Path_Switches (Id);
               Compiler :=
                 Get_Compiler_Driver_Path (Source_Project, Id.Language);

               if Compiler /= null then
                  if Id.Switches_Path /= No_Path then
                     --  Need to remove .cswi file so that it doesn't get
                     --  reused in case of compilation failure.

                     OS_Lib.Delete_File
                       (Get_Name_String (Id.Switches_Path), Dummy);
                  end if;

                  Spawn_Compiler_And_Register
                    (Source                 => Source,
                     Source_Project         => Source_Project,
                     Compiler_Path          => Compiler.all,
                     Mapping_File_Path      => Mapping_File,
                     Last_Switches_For_File => Last_Switches_For_File);
               end if;

            else
               Print_Compilation_Outputs (Id);

               if Source.Closure
                 or else
                   (Builder_Data (Source.Tree).Closure_Needed
                    and then
                    Id.Language.Config.Dependency_Kind in ALI_Dependency)
               then
                  Record_ALI_For (Source, The_ALI);

               else
                  ALI.Initialize_ALI;
               end if;
            end if;
         end if;
      end Process_Project_Phase_1;

      --------------------------------
      -- Must_Exit_Because_Of_Error --
      --------------------------------

      function Must_Exit_Because_Of_Error return Boolean is
         Source_Identity : Queue.Source_Info;
         Compilation_OK  : Boolean;
         Slave           : Unbounded_String;

         Cur : Bad_Compilations_Set.Cursor;
         OK  : Boolean;
      begin
         if not Bad_Compilations.Is_Empty and then not Opt.Keep_Going then
            while Outstanding_Compiles > 0 loop
               Await_Compile (Source_Identity, Compilation_OK, Slave);

               if not Compilation_OK then
                  Bad_Compilations.Insert
                    (Source_Identity.Id, To_String (Slave), Cur, OK);
               end if;
            end loop;

            return True;
         end if;
         return False;
      end Must_Exit_Because_Of_Error;

      -------------------------------
      -- Start_Compile_If_Possible --
      -------------------------------

      procedure Start_Compile_If_Possible is
         Found  : Boolean;
         Source : Queue.Source_Info;
      begin
         if not Queue.Is_Empty
           and then (Opt.Use_GNU_Make_Jobserver
                     or else Outstanding_Compiles < Get_Maximum_Processes)
         then
            Queue.Get (Found, Source);

            if Found then
               Initialize_Source_Record (Source.Id);
               Process_Project_Phase_1 (Source);
            end if;

            if Opt.Use_GNU_Make_Jobserver
              and then Unavailable_Token
            then
               null;
            elsif Found then
               Queue.Next;
            end if;
         end if;
      end Start_Compile_If_Possible;

      -----------------------------
      -- Wait_For_Available_Slot --
      -----------------------------

      procedure Wait_For_Available_Slot is
         Source_Identity : Queue.Source_Info;
         Compilation_OK  : Boolean;
         No_Check        : Boolean;
         Slave           : Unbounded_String;
         use Queue;

         Cur : Bad_Compilations_Set.Cursor;
         OK  : Boolean;

         function No_Slot_Available return Boolean;

         -----------------------
         -- No_Slot_Available --
         -----------------------

         function No_Slot_Available return Boolean is
         begin
            if Opt.Use_GNU_Make_Jobserver then
               return (Unavailable_Token
                       and then Registered_Processes);
            else
               return (Outstanding_Compiles = Get_Maximum_Processes);
            end if;
         end No_Slot_Available;
      begin
         if No_Slot_Available
           or else (Queue.Is_Virtually_Empty and then Outstanding_Compiles > 0)
         then
            Await_Compile (Source_Identity, Compilation_OK, Slave);

            if Compilation_OK
              and then Source_Identity /= Queue.No_Source_Info
            then
               --  Check if dependencies are on sources in Interfaces and,
               --  when --direct-import-only is used, the imported sources
               --  come from directly withed projects.

               Imports.Reset;
               Included_Sources.Clear;

               case Source_Identity.Id.Language.Config.Dependency_Kind is
                  when None     => null;
                  when Makefile =>
                     Compilation_OK := Phase_2_Makefile (Source_Identity);
                  when ALI_Dependency =>
                     Compilation_OK := Phase_2_ALI (Source_Identity);
               end case;

               --  If the compilation was invalidated, delete the compilation
               --  artifacts.

               if not Compilation_OK then
                  if Source_Identity.Id.Dep_Path /= No_Path
                    and then not Keep_Dep_File
                  then
                     Delete_File
                       (Get_Name_String (Source_Identity.Id.Dep_Path),
                        No_Check);
                  end if;

                  if Source_Identity.Id.Object_Path /= No_Path then
                     Delete_File
                       (Get_Name_String (Source_Identity.Id.Object_Path),
                        No_Check);
                  end if;

                  if Source_Identity.Id.Switches_Path /= No_Path then
                     Delete_File
                       (Get_Name_String (Source_Identity.Id.Switches_Path),
                        No_Check);
                  end if;
               end if;
            end if;

            if not Compilation_OK then
               Bad_Compilations.Insert
                 (Source_Identity.Id, To_String (Slave), Cur, OK);
            end if;
         end if;
      end Wait_For_Available_Slot;

   --  Start of processing for Compilation_Phase

   begin
      Outstanding_Compiles := 0;

      --  Then process each files in the queue (new files might be added to
      --  the queue as a result).

      Compilation_Loop :
      while not Queue.Is_Empty or else Outstanding_Compiles > 0 loop
         exit Compilation_Loop when Must_Exit_Because_Of_Error;
         Start_Compile_If_Possible;
         Wait_For_Available_Slot;

         if Opt.Display_Compilation_Progress then
            Put_Line
              ("completed" &
               Queue.Processed'Img &
               " out of" &
               Queue.Size'Img &
               " (" &
               Trim
                 (Source => Int (((Queue.Processed) * 100) / Queue.Size)'Img,
                  Side => Ada.Strings.Left) &
               "%)...");
         end if;

      end loop Compilation_Loop;

      --  Release local memory

      declare
         Data : Local_Project_Data :=
                  Local_Projects_HT.Get_First (Local_Projects);
      begin
         while Data /= No_Local_Project_Data loop
            Free (Data.Include_Path);
            Free (Data.Imported_Dirs_Switches);
            Data := Local_Projects_HT.Get_Next (Local_Projects);
         end loop;

         Local_Projects_HT.Reset (Local_Projects);
      end;
   end Compilation_Phase;

   ---------------------
   -- Project_Extends --
   ---------------------

   function Project_Extends
     (Extending : Project_Id;
      Extended  : Project_Id) return Boolean
   is
      Current : Project_Id := Extending;
   begin
      loop
         if Current = No_Project then
            return False;

         elsif Current = Extended then
            return True;
         end if;

         Current := Current.Extends;
      end loop;
   end Project_Extends;

end Gprbuild.Compile;
