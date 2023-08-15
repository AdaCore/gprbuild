------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2004-2023, AdaCore                     --
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

with Ada.Text_IO;       use Ada.Text_IO;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;

with GPR.Compilation.Slave; use GPR.Compilation.Slave;
with GPR.Jobserver;
with GPR.Names;             use GPR.Names;
with GPR.Script;            use GPR.Script;

package body Gprbuild is

   package Processed_Projects is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => Boolean,
      No_Element => False,
      Key        => Name_Id,
      Hash       => Hash,
      Equal      => "=");
   --  Projects that have already been processed

   ------------------
   -- Options_List --
   ------------------

   function Options_List (Options : Options_Data) return String_Vectors.Vector
   is
      Ret : String_Vectors.Vector;
   begin
      for Opt of Options loop
         Ret.Append (Opt.Name);
      end loop;

      return Ret;
   end Options_List;

   ----------------
   -- Add_Option --
   ----------------

   procedure Add_Option
     (Value       : Name_Id;
      To          : in out Options_Data;
      Display     : Boolean;
      Simple_Name : Boolean := False)
   is
   begin
      Add_Option (Get_Option (Value), To, Display, Simple_Name);
   end Add_Option;

   ----------------
   -- Add_Option --
   ----------------

   procedure Add_Option
     (Value       : String;
      To          : in out Options_Data;
      Display     : Boolean;
      Simple_Name : Boolean := False)
   is
   begin
      --  For compatibility with gnatmake, do not consider empty options

      if Value'Length = 0 then
         return;
      end if;

      To.Append
        (Option_Type'
           (Name_Len    => Value'Length,
            Name        => Value,
            Displayed   => Display,
            Simple_Name => Simple_Name));
   end Add_Option;

   ----------------------------------
   -- Add_Option_Internal_Codepeer --
   ----------------------------------

   procedure Add_Option_Internal_Codepeer
     (Value       : String;
      To          : in out Options_Data;
      Display     : Boolean;
      Simple_Name : Boolean := False)
   is
   begin
      if not Opt.CodePeer_Mode
        or else Value'Length <= 2
        or else Value (Value'First .. Value'First + 1) /= "-m"
      then
         Add_Option (Value, To, Display, Simple_Name);
      end if;
   end Add_Option_Internal_Codepeer;

   -----------------
   -- Add_Options --
   -----------------

   procedure Add_Options
     (Value         : String_List_Id;
      To            : in out Options_Data;
      Display_All   : Boolean;
      Display_First : Boolean;
      Simple_Name   : Boolean := False)
   is
      List            : String_List_Id := Value;
      Element         : String_Element;
      First_Display   : Boolean := Display_First;

   begin
      while List /= Nil_String loop
         Element := Project_Tree.Shared.String_Elements.Table (List);

         --  Ignore empty options

         if Element.Value /= Empty_String then

            Add_Option
              (Value       => Element.Value,
               To          => To,
               Display     => Display_All or First_Display,
               Simple_Name => Simple_Name);
            First_Display := False;
         end if;

         List := Element.Next;
      end loop;
   end Add_Options;

   -----------------
   -- Add_Process --
   -----------------

   procedure Add_Process (Process : Process_Id; Data : Process_Data) is
   begin
      Processes.Insert (Process, Data);
      Outstanding_Processes := Outstanding_Processes + 1;
   end Add_Process;

   --------------------
   -- Archive_Suffix --
   --------------------

   function Archive_Suffix (For_Project : Project_Id) return String is
   begin
      if For_Project.Config.Archive_Suffix = No_File then
         return ".a";

      else
         return Get_Name_String (For_Project.Config.Archive_Suffix);
      end if;
   end Archive_Suffix;

   -------------------
   -- Await_Process --
   -------------------

   procedure Await_Process (Data : out Process_Data; OK : out Boolean) is
      Pid : Process_Id;
      CP  : Process_Maps.Cursor;
   begin
      loop
         Data := No_Process_Data;

         Wait_Process (Pid, OK);

         if Pid = Invalid_Pid then
            return;
         end if;

         CP := Processes.Find (Pid);

         if Process_Maps.Has_Element (CP) then
            Data := Process_Maps.Element (CP);
            Processes.Delete (CP);
            Outstanding_Processes := Outstanding_Processes - 1;
            return;
         end if;
      end loop;
   end Await_Process;

   --------------------------------
   -- Change_To_Object_Directory --
   --------------------------------

   procedure Change_To_Object_Directory
     (Project          : Project_Id;
      Must_Be_Writable : Boolean := False)
   is
      Proj : constant Project_Id := Object_Project (Project, Must_Be_Writable);
   begin
      if Proj = No_Project then
         if Project.Qualifier = Aggregate
           or else Project.Qualifier = Aggregate_Library
         then
            Fail_Program
              (Project_Tree,
               "no project with writable object directory for project "
               & Get_Name_String (Project.Name),
               Exit_Code => E_General);

         else
            Fail_Program
              (Project_Tree,
               "object directory """
               & Get_Name_String (Project.Object_Directory.Display_Name)
               & """ for project """
               & Get_Name_String (Project.Name)
               & """ is not writable",
               Exit_Code => E_General);
         end if;
      end if;

      --  Nothing to do if the current working directory is already the correct
      --  object directory.

      if Project_Of_Current_Object_Directory /= Proj then
         Project_Of_Current_Object_Directory := Proj;

         --  Set the working directory to the object directory of the actual
         --  project.

         Script_Change_Dir (Proj.Object_Directory.Display_Name);
         Change_Dir (Get_Name_String (Proj.Object_Directory.Display_Name));

         if Opt.Verbose_Mode then
            Put  ("Changing to object directory of """);
            Put (Get_Name_String (Proj.Display_Name));
            Put  (""": """);
            Put (Get_Name_String (Proj.Object_Directory.Display_Name));
            Put_Line ("""");
         end if;
      end if;

   exception
      --  Fail if unable to change to the object directory

      when Directory_Error =>
         Fail_Program
           (Project_Tree,
            "unable to change to object directory """ &
            Get_Name_String (Project.Object_Directory.Display_Name) &
            """ of project " &
            Get_Name_String (Project.Display_Name));
   end Change_To_Object_Directory;

   ---------------------------
   -- Check_Archive_Builder --
   ---------------------------

   procedure Check_Archive_Builder is
      List : Name_List_Index;
   begin
      --  First, make sure that the archive builder (ar) is on the path

      if Archive_Builder_Path = null then
         List := Main_Project.Config.Archive_Builder;

         if List = No_Name_List then
            Fail_Program
              (Project_Tree, "no archive builder in configuration",
               Exit_Code => E_General);

         else
            Archive_Builder_Name :=
              new String'(Get_Name_String
                                     (Project_Tree.Shared.Name_Lists.Table
                                        (List).Name));
            Archive_Builder_Path :=
              Locate_Exec_On_Path (Archive_Builder_Name.all);

            if Archive_Builder_Path = null then
               Fail_Program
                 (Project_Tree,
                  "unable to locate archive builder """ &
                  Archive_Builder_Name.all & '"');
            end if;

            loop
               List := Project_Tree.Shared.Name_Lists.Table (List).Next;
               exit when List = No_Name_List;
               Add_Option
                 (Value   => Project_Tree.Shared.Name_Lists.Table (List).Name,
                  To      => Archive_Builder_Opts,
                  Display => True);
            end loop;

            List := Main_Project.Config.Archive_Builder_Append_Option;
            while List /= No_Name_List loop
               Add_Option
                 (Value   => Project_Tree.Shared.Name_Lists.Table (List).Name,
                  To      => Archive_Builder_Append_Opts,
                  Display => True);
               List := Project_Tree.Shared.Name_Lists.Table (List).Next;
            end loop;

            --  If there is an archive indexer (ranlib), try to locate it on
            --  the path. Don't fail if it is not found.

            List := Main_Project.Config.Archive_Indexer;

            if List /= No_Name_List then
               Archive_Indexer_Name :=
                 new String'(Get_Name_String
                   (Project_Tree.Shared.Name_Lists.Table (List).Name));
               Archive_Indexer_Path :=
                 Locate_Exec_On_Path (Archive_Indexer_Name.all);

               if Archive_Builder_Path /= null then
                  loop
                     List := Project_Tree.Shared.Name_Lists.Table (List).Next;
                     exit when List = No_Name_List;
                     Add_Option
                       (Value   =>
                          Project_Tree.Shared.Name_Lists.Table (List).Name,
                        To      => Archive_Indexer_Opts,
                        Display => True);
                  end loop;
               end if;
            end if;
         end if;
      end if;
   end Check_Archive_Builder;

   -----------------------
   -- Check_Export_File --
   -----------------------

   procedure Check_Export_File is
   begin
      if Main_Project.Config.Export_File_Switch /= No_Name then
         Export_File_Switch :=
           new String'
             (Get_Name_String (Main_Project.Config.Export_File_Switch));
      end if;

      Export_File_Format := Main_Project.Config.Export_File_Format;

      if Export_File_Switch /= null
        and then Export_File_Format = None
      then
         Fail_Program
           (Project_Tree,
            "attribute export_file_format must be defined"
            & " when export_file_switch is set.",
            Exit_Code => E_General);
      end if;
   end Check_Export_File;

   -------------------------------
   -- Check_Library_Symbol_File --
   -------------------------------

   procedure Check_Library_Symbol_File is
   begin
      if Main_Project.Symbol_Data.Symbol_File /= No_Path then
         Library_Symbol_File :=
           new String'(Get_Name_String (Main_Project.Symbol_Data.Symbol_File));
      end if;
   end Check_Library_Symbol_File;

   -------------------------
   -- Check_Object_Lister --
   -------------------------

   procedure Check_Object_Lister is
      List : Name_List_Index;
   begin
      --  First, make sure that the object lister (nm) is on the path

      if Object_Lister_Path = null then
         List := Main_Project.Config.Object_Lister;

         if List /= No_Name_List then
            Object_Lister_Name :=
              new String'(Get_Name_String
                          (Project_Tree.Shared.Name_Lists.Table (List).Name));

            Object_Lister_Path :=
              Locate_Exec_On_Path (Object_Lister_Name.all);

            if Object_Lister_Path = null then
               Fail_Program
                 (Project_Tree,
                  "unable to locate object lister """ &
                  Object_Lister_Name.all & '"');
            end if;

            loop
               List := Project_Tree.Shared.Name_Lists.Table (List).Next;
               exit when List = No_Name_List;
               Add_Option
                 (Value   => Project_Tree.Shared.Name_Lists.Table (List).Name,
                  To      => Object_Lister_Opts,
                  Display => True);
            end loop;
         end if;

         --  Check object matcher

         if Main_Project.Config.Object_Lister_Matcher /= No_Name then
            Object_Lister_Matcher :=
              new String'
                (Get_Name_String (Main_Project.Config.Object_Lister_Matcher));
         end if;

         if Object_Lister_Path /= null
           and then Object_Lister_Matcher = null
         then
            Fail_Program
              (Project_Tree,
               "attribute object_lister_matcher must be defined when"
               & " object_lister is set.",
               Exit_Code => E_General);
         end if;
      end if;
   end Check_Object_Lister;

   ---------------------------
   -- Create_Path_From_Dirs --
   ---------------------------

   function Create_Path_From_Dirs return String_Access is
      Result    : String_Access;
      Tmp       : String_Access;
      Path_Last : Natural := 0;
   begin
      for Index in 1 .. Directories.Last loop
         Get_Name_String (Directories.Table (Index));

         while Name_Len > 1
           and then (Name_Buffer (Name_Len) = Directory_Separator
                     or else Name_Buffer (Name_Len) = '/')
         loop
            Name_Len := Name_Len - 1;
         end loop;

         if Result = null then
            Result := new String (1 .. Name_Len);
         else
            while Path_Last + Name_Len + 1 > Result'Last loop
               Tmp := new String (1 .. 2 * Result'Length);
               Tmp (1 .. Path_Last) := Result (1 .. Path_Last);
               Free (Result);
               Result := Tmp;
            end loop;

            Path_Last := Path_Last + 1;
            Result (Path_Last) := Path_Separator;
         end if;

         Result (Path_Last + 1 .. Path_Last + Name_Len) :=
           Name_Buffer (1 .. Name_Len);
         Path_Last := Path_Last + Name_Len;
      end loop;

      if Current_Verbosity = High and then Result /= null then
         Put_Line ("Path=" & Result (1 .. Path_Last));
      end if;

      Tmp := new String'(Result (1 .. Path_Last));
      Free (Result);
      return Tmp;
   end Create_Path_From_Dirs;

   -----------------------
   -- Display_Processes --
   -----------------------

   procedure Display_Processes (Name : String) is
   begin
      if (if Name = "bind" then Opt.Maximum_Binders
          elsif Name = "link" then Opt.Maximum_Linkers
          else Opt.Maximum_Compilers) > 1
        and then Opt.Verbose_Mode
        and then Current_Verbosity = High
      then
         Put ("   ");
         Put (Outstanding_Processes'Img);
         Put (' ');
         Put (Name);

         if Outstanding_Processes <= 1 then
            Put_Line (" process");
         else
            Put_Line (" processes");
         end if;
      end if;
   end Display_Processes;

   ----------------
   -- Get_Option --
   ----------------

   function Get_Option
     (Option : Name_Id) return String renames Get_Name_String;

   ----------
   -- Hash --
   ----------

   function Hash (Pid : Process_Id) return Ada.Containers.Hash_Type is
   begin
      return Ada.Containers.Hash_Type (Pid_To_Integer (Pid));
   end Hash;

   --------------------------------
   -- Process_Imported_Libraries --
   --------------------------------

   procedure Process_Imported_Libraries
     (For_Project        : Project_Id;
      There_Are_SALs     : out Boolean;
      And_Project_Itself : Boolean := False)
   is

      procedure Process_Project (Project : Project_Id; Aggregated : Boolean);
      --  Process Project and its imported projects recursively.
      --  Add any library projects to table Library_Projs.

      ---------------------
      -- Process_Project --
      ---------------------

      procedure Process_Project
        (Project : Project_Id; Aggregated : Boolean)
      is
         Imported : Project_List := Project.Imported_Projects;

      begin
         --  Nothing to do if project has already been processed

         if not Processed_Projects.Get (Project.Name) then
            Processed_Projects.Set (Project.Name, True);

            --  For an extending project, process the project being extended

            if Project.Extends /= No_Project then
               Process_Project (Project.Extends, Aggregated => Aggregated);
            end if;

            --  We first process the imported projects to guarantee that
            --  We have a proper reverse order for the libraries. Do not add
            --  library for encapsulated libraries dependencies except when
            --  building the encapsulated library itself. Also, do not add
            --  libraries aggregated from an aggregate library.

            if For_Project.Standalone_Library = Encapsulated
              or else Project.Standalone_Library /= Encapsulated
            then
               while Imported /= null loop
                  if Imported.Project /= No_Project then
                     Process_Project
                       (Imported.Project,
                        Aggregated => Project.Qualifier = Aggregate_Library);
                  end if;

                  Imported := Imported.Next;
               end loop;
            end if;

            --  If it is a library project, add it to Library_Projs

            if (And_Project_Itself or else Project /= For_Project)
              and then Project.Extended_By = No_Project
              and then Project.Library
            then
               if Project.Standalone_Library /= No then
                  There_Are_SALs := True;
               end if;

               Library_Projs.Append
                 (Library_Project'
                    (Project,
                     Aggregated and then not Project.Externally_Built));
            end if;
         end if;
      end Process_Project;

      --  Start of processing for Process_Imported_Libraries

   begin
      Processed_Projects.Reset;
      Library_Projs.Clear;
      There_Are_SALs := False;

      Process_Project (For_Project, Aggregated => False);
   end Process_Imported_Libraries;

   ------------------------------------
   -- Process_Imported_Non_Libraries --
   ------------------------------------

   procedure Process_Imported_Non_Libraries (For_Project : Project_Id) is

      procedure Process_Project (Project : Project_Id);
      --  Process Project and its imported projects recursively.
      --  Add any non library project to table Non_Library_Projs.

      ---------------------
      -- Process_Project --
      ---------------------

      procedure Process_Project (Project : Project_Id) is
         Imported : Project_List := Project.Imported_Projects;

      begin
         --  Nothing to do if project has already been processed

         if not Processed_Projects.Get (Project.Name) then
            Processed_Projects.Set (Project.Name, True);

            --  Call Process_Project recursively for any imported project.
            --  We first process the imported projects to guarantee that
            --  we have a proper reverse order for the libraries.

            while Imported /= null loop
               if Imported.Project /= No_Project then
                  Process_Project (Imported.Project);
               end if;

               Imported := Imported.Next;
            end loop;

            --  For an extending project, process the project being extended

            if Project.Extends /= No_Project then
               Process_Project (Project.Extends);
            end if;

            --  If it is not a library project, add it to Non_Library_Projs

            if Project /= For_Project
              and then Project.Extended_By = No_Project
              and then not Project.Library
            then
               Non_Library_Projs.Append (Project);
            end if;
         end if;
      end Process_Project;

      --  Start of processing for Process_Imported_Non_Libraries

   begin
      Processed_Projects.Reset;
      Non_Library_Projs.Clear;

      Process_Project (For_Project);
   end Process_Imported_Non_Libraries;

   --------------------
   -- Record_Failure --
   --------------------

   procedure Record_Failure (Main : Main_Info) is
   begin
      Bad_Processes.Append (Main);

      if not Opt.Keep_Going then
         Stop_Spawning := True;
      end if;

      if Exit_Code = E_Success then
         Exit_Code := Osint.E_Fatal;
      end if;
   end Record_Failure;

   ------------------------
   -- Sigint_Intercepted --
   ------------------------

   procedure Sigint_Intercepted is
   begin
      Put_Line ("*** Interrupted ***");
      Delete_All_Temp_Files (Project_Tree.Shared);

      GPR.Jobserver.Unregister_All_Token_Id;

      if Distributed_Mode then
         Unregister_Remote_Slaves (From_Signal => True);
      end if;

      OS_Exit (2);
   end Sigint_Intercepted;

   -----------------------------
   -- String_Vector_To_String --
   -----------------------------

   function String_Vector_To_String
     (SV : String_Vectors.Vector) return String is
   begin
      Name_Len := 0;
      for S of SV loop
         Add_Str_To_Name_Buffer (S & " ");
      end loop;
      return Name_Buffer (1 .. Name_Len);
   end String_Vector_To_String;

   ---------------------------
   -- Test_If_Relative_Path --
   ---------------------------

   --  ??? TODO: this is so wrong: procedure with a name Test_Something that
   --  changes the value of what it tests... Shroedinger, please help me, the
   --  cat doesn't have to die!
   procedure Test_If_Relative_Path
     (Switch           : in out String_Access;
      Parent           : String;
      Including_Switch : Name_Id)
   is
      Original : constant String (1 .. Switch'Length) := Switch.all;

   begin
      if Original (1) = '-' and then Including_Switch /= No_Name then
         declare
            Inc_Switch : constant String := Get_Name_String (Including_Switch);

         begin
            if Original'Last > Inc_Switch'Last
              and then Original (1 .. Inc_Switch'Last) = Inc_Switch
              and then not Is_Absolute_Path
                (Original (Inc_Switch'Last + 1 .. Original'Last))
            then
               declare
                  Dir : constant String :=
                    Parent &
                    Directory_Separator &
                    Original (Inc_Switch'Last + 1 .. Original'Last);
               begin
                  if Is_Directory (Dir) then
                     Free (Switch);
                     Switch := new String'(Inc_Switch & Dir);
                  end if;
               end;
            end if;
         end;
      end if;

      if Original (1) /= '-' and then not Is_Absolute_Path (Original) then
         declare
            File : constant String := Parent & Directory_Separator & Original;
         begin
            if Is_Regular_File (File) then
               Free (Switch);
               Switch := new String'(File);
            end if;
         end;
      end if;
   end Test_If_Relative_Path;

end Gprbuild;
