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

with Ada.Calendar;               use Ada.Calendar;
with Ada.Containers.Indefinite_Hashed_Maps;
with Ada.Containers.Vectors;
with Ada.Strings.Fixed;          use Ada.Strings.Fixed;
with Ada.Strings.Hash;
with Ada.Text_IO;                use Ada.Text_IO;
with Ada.Unchecked_Deallocation; use Ada;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.Expect;
with GNAT.Strings;

with Gpr_Build_Util; use Gpr_Build_Util;
with Gprexch;        use Gprexch;
with GPR.Err;        use GPR.Err;
with GPR.Erroutc;    use GPR.Erroutc;
with GPR.Debug;      use GPR.Debug;
with GPR.Names;      use GPR.Names;
with GPR.Script;     use GPR.Script;
with GPR.Snames;     use GPR.Snames;
with GPR.Util.Aux;   use GPR.Util;
with GPR.Tempdir;

package body Gprbuild.Link is

   type Archive_Data is record
      Checked        : Boolean := False;
      Has_Been_Built : Boolean := False;
      Exists         : Boolean := False;
   end record;

   type Source_Index_Rec is record
      Project : Project_Id;
      Id      : Source_Id;
      Found   : Boolean := False;
   end record;
   --  Used as Source_Indexes component to check if archive needs to be rebuilt

   type Source_Index_Array is array (Positive range <>) of Source_Index_Rec;
   type Source_Indexes_Ref is access Source_Index_Array;

   procedure Free is new Unchecked_Deallocation
     (Source_Index_Array, Source_Indexes_Ref);

   Initial_Source_Index_Count : constant Positive := 20;
   Source_Indexes : Source_Indexes_Ref :=
     new Source_Index_Array (1 .. Initial_Source_Index_Count);
   --  A list of the Source_Ids, with an indication that they have been found
   --  in the archive dependency file.

   type Linker_Options_Data is record
      Project : Project_Id;
      Options : String_List_Id;
   end record;

   package Linker_Options_Vector is new Ada.Containers.Vectors
     (Positive, Linker_Options_Data);

   procedure Build_Global_Archive
     (For_Project    : Project_Id;
      Project_Tree   : Project_Tree_Ref;
      Has_Been_Built : out Boolean;
      Exists         : out Boolean;
      Command        : out String_Vectors.Vector;
      OK             : out Boolean);
   --  Build, if necessary, the global archive for a main project.
   --  Out parameter Has_Been_Built is True iff the global archive has been
   --  built/rebuilt. Exists is False if there is no need for a global archive.
   --  OK is False when there is a problem building the global archive.

   procedure Link_Main (Main_File : in out Main_Info);
   --  Link a specific main unit

   procedure Add_Linker_Options
     (Arguments   : in out Options_Data;
      For_Project : Project_Id);
   --  Get the Linker_Options from a project

   procedure Add_Rpath
     (Rpath : in out String_Vectors.Vector;
      Path  : String);
   --  Add a path name to Rpath

   procedure Add_Rpath_From_Arguments
     (Rpath     : in out String_Vectors.Vector;
      Arguments : Options_Data;
      Project   : Project_Id);
   --  Add all explicit -L directives as an rpath

   procedure Rpaths_Relative_To
     (Rpaths   : in out String_Vectors.Vector;
      Exec_Dir : Path_Name_Type;
      Origin   : Name_Id);
   --  Change all paths in table Rpaths to paths relative to Exec_Dir, if they
   --  have at least one non root directory in common.

   function Is_In_Library_Project (Object_Path : String) return Boolean;
   --  Return True if Object_Path is the path of an object file in a library
   --  project.

   function Is_Object (Filename : String) return Boolean
   is (Filename'Length > Object_Suffix'Length
       and then
       Filename (Filename'Last - Object_Suffix'Length + 1 .. Filename'Last)
       = Object_Suffix);
   --  Returns True if filename ended with Object_Suffix

   procedure Display_Command
     (Arguments : Options_Data;
      Path      : String_Access;
      Ellipse   : Boolean := False);
   --  Display the command for a spawned process, if in Verbose_Mode or not in
   --  Quiet_Output. In non verbose mode, when Ellipse is True, display "..."
   --  in place of the first argument that has Display set to False.

   procedure Add_Argument
     (Arguments   : in out Options_Data;
      Arg         : String;
      Display     : Boolean;
      Simple_Name : Boolean := False);
   --  Add an argument to Arguments. Reallocate if necessary

   procedure Add_Arguments
     (Arguments   : in out Options_Data;
      Args        : String_Vectors.Vector;
      Display     : Boolean;
      Simple_Name : Boolean := False);
   --  Add a list of arguments to Arguments. Reallocate if necessary

   No_Archive_Data : constant Archive_Data :=
                       (Checked        => False,
                        Has_Been_Built => False,
                        Exists         => False);

   package Global_Archives_Built is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => Archive_Data,
      No_Element => No_Archive_Data,
      Key        => Name_Id,
      Hash       => GPR.Hash,
      Equal      => "=");
   --  A hash table to record what global archives have been already built

   Path_Options : String_Vectors.Vector;
   --  Directories coming from the binder exchange file

   package Library_Dirs is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => Boolean,
      No_Element => False,
      Key        => Path_Name_Type,
      Hash       => Hash,
      Equal      => "=");
   --  A hash table to store the library dirs, to avoid repeating uselessly
   --  the same switch when linking executables.

   Last_Source : Natural := 0;
   --  The index of the last valid component of Source_Indexes

   ------------------
   -- Add_Argument --
   ------------------

   procedure Add_Argument
     (Arguments   : in out Options_Data;
      Arg         : String;
      Display     : Boolean;
      Simple_Name : Boolean := False)
   is
   begin
      --  Nothing to do if no argument is specified or if argument is empty

      if Arg'Length /= 0 then
         --  Add the argument and its display indication
         Arguments.Append
           (Option_Type'
              (Name_Len    => Arg'Length,
               Name        => Arg,
               Displayed   => Display,
               Simple_Name => Simple_Name));
      end if;
   end Add_Argument;

   -------------------
   -- Add_Arguments --
   -------------------

   procedure Add_Arguments
     (Arguments   : in out Options_Data;
      Args        : String_Vectors.Vector;
      Display     : Boolean;
      Simple_Name : Boolean := False)
   is
   begin
      --  Add the new arguments and the display indications

      for Arg of Args loop
         Add_Argument (Arguments, Arg, Display, Simple_Name);
      end loop;
   end Add_Arguments;

   ---------------
   -- Add_Rpath --
   ---------------

   procedure Add_Rpath
     (Rpath : in out String_Vectors.Vector;
      Path  : String)
   is
      --  Rpaths are always considered case sensitive, as it's a runtime
      --  property of dynamic objects, so in case of cross compilation is
      --  independent of the host's way of handling case sensitivity
      Normalized : constant String :=
                     Normalize_Pathname
                       (Path,
                        Resolve_Links  => Opt.Follow_Links_For_Dirs,
                        Case_Sensitive => True);
   begin
      --  Nothing to do if Path is empty

      if Path'Length = 0 then
         return;
      end if;

      --  Nothing to do if the directory is already in the Rpaths table
      for Path of Rpath loop
         if Path = Normalized then
            return;
         end if;
      end loop;

      Rpath.Append (Normalized);
   end Add_Rpath;

   ------------------------------
   -- Add_Rpath_From_Arguments --
   ------------------------------

   procedure Add_Rpath_From_Arguments
     (Rpath     : in out String_Vectors.Vector;
      Arguments : Options_Data;
      Project   : Project_Id)
   is
      LSwitch : constant String :=
                  (if Project.Config.Linker_Lib_Dir_Option = No_Name
                   then "-L"
                   else
                      Get_Name_String (Project.Config.Linker_Lib_Dir_Option));
   begin
      for Arg of Arguments loop
         if Arg.Name_Len > LSwitch'Length
           and then Arg.Name (Arg.Name'First ..
                                Arg.Name'First + LSwitch'Length - 1) = LSwitch
         then
            Add_Rpath
              (Rpath,
               Arg.Name (Arg.Name'First + LSwitch'Length .. Arg.Name'Last));
         end if;
      end loop;
   end Add_Rpath_From_Arguments;

   --------------------------
   -- Build_Global_Archive --
   --------------------------

   procedure Build_Global_Archive
     (For_Project    : Project_Id;
      Project_Tree   : Project_Tree_Ref;
      Has_Been_Built : out Boolean;
      Exists         : out Boolean;
      Command        : out String_Vectors.Vector;
      OK             : out Boolean)
   is
      Archive_Name : constant String :=
                       "lib"
                       & Get_Name_String (For_Project.Name)
                       & Archive_Suffix (For_Project);
      --  The name of the archive file for this project

      Archive_Dep_Name : constant String :=
                           "lib"
                           & Get_Name_String (For_Project.Name) & ".deps";
      --  The name of the archive dependency file for this project

      File : GPR.Util.Text_File;

      Object_Path  : Path_Name_Type;
      Time_Stamp   : Time_Stamp_Type;

      First_Object : Natural;
      Current_Object : Positive;

      Discard : Boolean;

      Proj_List    : Project_List;

      Src_Id       : Source_Id;
      S_Id         : Source_Id;

      Success      : Boolean;

      Size : Natural;

      Global_Archive_Data : Archive_Data;

      Need_To_Build : Boolean;

      Arguments     : Options_Data;

      Objects       : String_Vectors.Vector;

      procedure Add_Sources (Proj : Project_Id);
      --  Add all the sources of project Proj to Sources_Index

      function Get_Objects (Proj : Project_Id) return String_Vectors.Vector;
      --  Add all the object paths of project Proj to Arguments

      procedure Handle_Failure;

      procedure Report_Status
        (Archive_Built : Boolean;
         Archive_Exists : Boolean);

      -----------------
      -- Add_Sources --
      -----------------

      procedure Add_Sources (Proj : Project_Id) is
         Project : Project_Id := Proj;
         Id      : Source_Id;
         Iter    : Source_Iterator;

         procedure Add_Source_Id (Project : Project_Id; Id : Source_Id);
         --  Add a source id to Source_Indexes, with Found set to False

         -------------------
         -- Add_Source_Id --
         -------------------

         procedure Add_Source_Id (Project : Project_Id; Id : Source_Id) is
         begin
            --  Reallocate the array, if necessary

            if Last_Source = Source_Indexes'Last then
               declare
                  New_Indexes : constant Source_Indexes_Ref :=
                                  new Source_Index_Array
                                    (1 .. Source_Indexes'Last +
                                                   Initial_Source_Index_Count);
               begin
                  New_Indexes (Source_Indexes'Range) := Source_Indexes.all;
                  Free (Source_Indexes);
                  Source_Indexes := New_Indexes;
               end;
            end if;

            Last_Source := Last_Source + 1;
            Source_Indexes (Last_Source) := (Project, Id, False);
         end Add_Source_Id;

      begin
         while Project /= No_Project loop
            Iter := For_Each_Source (Project_Tree, Project);
            loop
               Id := GPR.Element (Iter);
               exit when Id = No_Source;

               if Is_Compilable (Id)
                 and then Id.Kind = Impl
                 and then Id.Unit = No_Unit_Index
               then
                  Add_Source_Id (Proj, Id);
               end if;

               Next (Iter);
            end loop;

            Project := Project.Extends;
         end loop;
      end Add_Sources;

      -----------------
      -- Add_Objects --
      -----------------

      function Get_Objects (Proj : Project_Id) return String_Vectors.Vector
      is
         Project : Project_Id := Proj;
         Id      : Source_Id;
         Iter    : Source_Iterator;
         Ret     : String_Vectors.Vector;

         package Sort is new String_Vectors.Generic_Sorting;

      begin
         loop
            if Project.Object_Directory /= No_Path_Information then
               if Project.Externally_Built then
                  --  If project is externally built, include all object files
                  --  in the object directory in the global archive.

                  declare
                     Obj_Dir : constant String :=
                                 Get_Name_String
                                   (Project.Object_Directory.Display_Name);
                     Dir_Obj : Dir_Type;

                  begin
                     if Is_Regular_File (Obj_Dir) then
                        Open (Dir_Obj, Obj_Dir);

                        loop
                           Read (Dir_Obj, Name_Buffer, Name_Len);
                           exit when Name_Len = 0;

                           Canonical_Case_File_Name
                             (Name_Buffer (1 .. Name_Len));

                           if Is_Object (Name_Buffer (1 .. Name_Len)) then
                              Ret.Append
                                (Obj_Dir & Directory_Separator
                                 & Name_Buffer (1 .. Name_Len));
                           end if;
                        end loop;

                        Close (Dir_Obj);
                     end if;
                  end;

               else
                  Iter := For_Each_Source (Project_Tree, Project);
                  loop
                     Id := GPR.Element (Iter);
                     exit when Id = No_Source;

                     if Object_To_Global_Archive (Id) then
                        --  The source record may not be initialized if
                        --  gprbuild was called with the switch -l.

                        Initialize_Source_Record (Id);

                        Ret.Append (Get_Name_String (Id.Object_Path));
                     end if;

                     Next (Iter);
                  end loop;
               end if;
            end if;

            Project := Project.Extends;

            exit when Project = No_Project;
         end loop;

         --  Make sure the objects are sorted alphabetically
         Sort.Sort (Ret);

         return Ret;
      end Get_Objects;

      --------------------
      -- Handle_Failure --
      --------------------

      procedure Handle_Failure is
      begin
         --  Building the archive failed, delete dependency file if
         --  one exists.

         if Is_Regular_File (Archive_Dep_Name) then
            Delete_File (Archive_Dep_Name, Success);
         end if;

         Put ("global archive for project ");
         Put (Get_Name_String (For_Project.Display_Name));
         Put_Line (" could not be built");
         OK := False;
      end Handle_Failure;

      -------------------
      -- Report_Status --
      -------------------

      procedure Report_Status
        (Archive_Built : Boolean;
         Archive_Exists : Boolean)
      is
      begin
         Has_Been_Built := Archive_Built;
         Exists         := Archive_Exists;

         Global_Archives_Built.Set
           (Name_Id (For_Project.Path.Name),
            (Checked        => True,
             Has_Been_Built => Archive_Built,
             Exists         => Archive_Exists));
      end Report_Status;

   begin
      Exists := False;
      Has_Been_Built := False;
      OK := True;

      if For_Project.Object_Directory = No_Path_Information then
         return;
      end if;

      --  No need to build the global archive, if it has already been done

      Global_Archive_Data :=
        Global_Archives_Built.Get (Name_Id (For_Project.Path.Name));

      if Global_Archive_Data.Checked then
         Has_Been_Built := Global_Archive_Data.Has_Been_Built;
         Exists         := Global_Archive_Data.Exists;

         --  No processing needed: already processed. Let's return
         return;
      end if;

      Change_To_Object_Directory (For_Project);

      --  Put all non Ada sources in the project tree in Source_Indexes

      Last_Source := 0;

      Add_Sources (For_Project);

      Proj_List := For_Project.All_Imported_Projects;

      while Proj_List /= null loop
         if not Proj_List.Project.Library then
            Add_Sources (Proj_List.Project);
         end if;

         Proj_List := Proj_List.Next;
      end loop;

      Need_To_Build := Opt.Force_Compilations;

      if not Need_To_Build then
         if Opt.Verbosity_Level > Opt.Low then
            Put ("   Checking ");
            Put (Archive_Name);
            Put_Line (" ...");
         end if;

         --  If the archive does not exist, of course it needs to be
         --  built.

         if not Is_Regular_File (Archive_Name) then
            Need_To_Build := True;

            if Opt.Verbosity_Level > Opt.Low then
               Put_Line ("      -> archive does not exist");
            end if;

         else
            --  Archive does exist

            --  Check the archive dependency file

            Open (File, Archive_Dep_Name);

            --  If the archive dependency file does not exist, we need to
            --  to rebuild the archive and to create its dependency file.

            if not Is_Valid (File) then
               Need_To_Build := True;

               if Opt.Verbosity_Level > Opt.Low then
                  Put ("      -> archive dependency file ");
                  Put (Archive_Dep_Name);
                  Put_Line (" does not exist");
               end if;

            else
               --  Read the dependency file, line by line

               while not End_Of_File (File) loop
                  Get_Line (File, Name_Buffer, Name_Len);

                  --  First line is the path of the object file

                  Object_Path := Name_Find;
                  Src_Id := No_Source;

                  --  Check if this object file is for a source of this
                  --  project.

                  for S in 1 .. Last_Source loop
                     S_Id := Source_Indexes (S).Id;

                     if not Source_Indexes (S).Found
                       and then S_Id.Object_Path = Object_Path
                     then
                        --  We have found the object file: get the
                        --  source data, and mark it as found.

                        Src_Id := S_Id;
                        Source_Indexes (S).Found := True;
                        exit;
                     end if;
                  end loop;

                  --  If it is not for a source of this project, then the
                  --  archive needs to be rebuilt.

                  if Src_Id = No_Source then
                     Need_To_Build := True;
                     if Opt.Verbosity_Level > Opt.Low then
                        Put ("      -> ");
                        Put (Get_Name_String (Object_Path));
                        Put_Line (" is not an object of any project");
                     end if;

                     exit;
                  end if;

                  --  The second line is the time stamp of the object
                  --  file. If there is no next line, then the dependency
                  --  file is truncated, and the archive need to be
                  --  rebuilt.

                  if End_Of_File (File) then
                     Need_To_Build := True;

                     if Opt.Verbosity_Level > Opt.Low then
                        Put ("      -> archive dependency file ");
                        Put_Line (" is truncated");
                     end if;

                     exit;
                  end if;

                  Get_Line (File, Name_Buffer, Name_Len);

                  --  If the line has the wrong number of characters,
                  --  then the dependency file is incorrectly formatted,
                  --  and the archive needs to be rebuilt.

                  if Name_Len /= Time_Stamp_Length then
                     Need_To_Build := True;

                     if Opt.Verbosity_Level > Opt.Low then
                        Put ("      -> archive dependency file ");
                        Put_Line (" is incorrectly formatted (time stamp)");
                     end if;

                     exit;
                  end if;

                  Time_Stamp := Time_Stamp_Type (Name_Buffer (1 .. Name_Len));

                  --  If the time stamp in the dependency file is
                  --  different from the time stamp of the object file,
                  --  then the archive needs to be rebuilt. The
                  --  comparaison is done with String type values,
                  --  because two values of type Time_Stamp_Type are
                  --  equal if they differ by 2 seconds or less; here the
                  --  check is for an exact match.

                  if String (Time_Stamp) /= String (Src_Id.Object_TS) then
                     Need_To_Build := True;

                     if Opt.Verbosity_Level > Opt.Low then
                        Put ("      -> time stamp of ");
                        Put (Get_Name_String (Object_Path));
                        Put (" is incorrect in the archive");
                        Put_Line (" dependency file");
                        Put ("         recorded time stamp: ");
                        Put_Line (String (Time_Stamp));
                        Put ("           actual time stamp: ");
                        Put_Line (String (Src_Id.Object_TS));
                     end if;

                     exit;

                  elsif Debug_Flag_T then
                     Put ("      -> time stamp of ");
                     Put (Get_Name_String (Object_Path));
                     Put (" is correct in the archive");
                     Put_Line (" dependency file");
                     Put ("         recorded time stamp: ");
                     Put_Line (String (Time_Stamp));
                     Put ("           actual time stamp: ");
                     Put_Line (String (Src_Id.Object_TS));
                  end if;
               end loop;

               Close (File);
            end if;
         end if;
      end if;

      if not Need_To_Build then
         for S in 1 .. Last_Source loop
            if not Source_Indexes (S).Found
              and then Object_To_Global_Archive (Source_Indexes (S).Id)
            then
               Need_To_Build := True;

               if Opt.Verbosity_Level > Opt.Low then
                  Put ("      -> object file ");
                  Put (Get_Name_String (Source_Indexes (S).Id.Object_Path));
                  Put_Line (" is not in the dependency file");
               end if;

               exit;
            end if;
         end loop;
      end if;

      if not Need_To_Build then
         if Opt.Verbosity_Level > Opt.Low then
            Put_Line ("      -> up to date");
         end if;

         Report_Status (Archive_Built => False, Archive_Exists => True);

         --  No processing needed: up-to-date. Let's return
         return;
      end if;

      --  Archive needs to be rebuilt
      Check_Archive_Builder;

      --  If archive already exists, first delete it, but if this is
      --  not possible, continue: if archive cannot be built, we will
      --  fail later on.

      if Is_Regular_File (Archive_Name) then
         Delete_File (Archive_Name, Discard);
      end if;

      --  Get all the object files of the non library projects

      Objects := Get_Objects (For_Project);

      Proj_List := For_Project.All_Imported_Projects;

      while Proj_List /= null loop
         if not Proj_List.Project.Library then
            Objects.Append_Vector (Get_Objects (Proj_List.Project));
         end if;

         Proj_List := Proj_List.Next;
      end loop;

      --  No global archive, if there is no object file to put into

      if Objects.Is_Empty then
         if Opt.Verbosity_Level > Opt.Low then
            Put_Line ("      -> there is no global archive");
         end if;

         Report_Status (Archive_Built => False, Archive_Exists => False);

         return;
      end if;

      First_Object := Objects.First_Index;

      --  If there is an Archive_Builder_Append_Option, we may have
      --  to build the archive in chunks.

      loop
         Arguments.Clear;
         Command.Clear;

         --  Start with the minimal options

         if First_Object = Objects.First_Index then
            --  Creation of a new archive
            Arguments.Append_Vector (Archive_Builder_Opts);
         else
            --  Append objects to an existing archive
            Arguments.Append_Vector (Archive_Builder_Append_Opts);
         end if;

         --  Followed by the archive name

         Add_Argument
           (Arguments,
            Archive_Name,
            Display     => True,
            Simple_Name => not Opt.Verbose_Mode);

         if Archive_Builder_Append_Opts.Is_Empty then
            Current_Object := Objects.Last_Index;

         else
            Size := 0;
            for Arg of Arguments loop
               Size := Size + Arg.Name_Len + 1;
            end loop;

            for J in First_Object .. Objects.Last_Index loop
               Size := Size + Objects.Element (J)'Length + 1;
               exit when Size > Maximum_Size;
               Current_Object := J;
            end loop;
         end if;

         for J in First_Object .. Current_Object loop
            Add_Argument
              (Arguments,
               Objects (J),
               Display     => Opt.Verbose_Mode,
               Simple_Name => not Opt.Verbose_Mode);
         end loop;

         First_Object := Current_Object + 1;

         if not Opt.Quiet_Output then
            if Opt.Verbose_Mode then
               Display_Command
                 (Arguments,
                  Archive_Builder_Path,
                  Ellipse => True);

            else
               Display
                 (Section  => GPR.Link,
                  Command  => "archive",
                  Argument => Archive_Name);
            end if;
         end if;

         declare
            Options : String_Vectors.Vector;
         begin
            Command.Append (Archive_Builder_Path.all);

            for Arg of Arguments loop
               Options.Append (Arg.Name);
               Command.Append (Arg.Name);
            end loop;

            Spawn_And_Script_Write
              (Archive_Builder_Path.all, Options, Success);
         end;

         if not Success then
            Handle_Failure;

            return;
         end if;

         --  Continue until all objects are in the archive
         exit when First_Object > Objects.Last_Index;
      end loop;

      --  The archive was built, run the archive indexer
      --  (ranlib) if there is one.

      if Archive_Indexer_Path /= null then
         Arguments.Clear;
         Command.Clear;

         Arguments.Append_Vector (Archive_Indexer_Opts);
         Add_Argument
           (Arguments,
            Archive_Name,
            True,
            Simple_Name => not Opt.Verbose_Mode);

         if not Opt.Quiet_Output then
            if Opt.Verbose_Mode then
               Display_Command
                 (Arguments,
                  Archive_Indexer_Path);

            else
               Display
                 (Section  => GPR.Link,
                  Command  => "index",
                  Argument => Archive_Name);
            end if;
         end if;

         declare
            Options : String_Vectors.Vector;
         begin
            Command.Append (Archive_Indexer_Path.all);

            for Arg of Arguments loop
               Options.Append (Arg.Name);
               Command.Append (Arg.Name);
            end loop;

            Spawn_And_Script_Write
              (Archive_Indexer_Path.all, Options, Success);
         end;

         if not Success then
            --  Running the archive indexer failed, delete the
            --  dependency file, if it exists.

            if Is_Regular_File (Archive_Dep_Name) then
               Delete_File (Archive_Dep_Name, Success);
            end if;

            Handle_Failure;

            return;
         end if;
      end if;

      --  The archive was correctly built, create its dependency
      --  file.

      declare
         Dep_File : Text_IO.File_Type;

      begin
         --  Create the file in Append mode, to avoid automatic
         --  insertion of an end of line if file is empty.

         Create (Dep_File, Append_File, Archive_Dep_Name);

         for S in 1 .. Last_Source loop
            Src_Id := Source_Indexes (S).Id;
            if Object_To_Global_Archive (Src_Id) then
               Put_Line (Dep_File, Get_Name_String (Src_Id.Object_Path));
               Put_Line (Dep_File, String (Src_Id.Object_TS));
            end if;
         end loop;

         Close (Dep_File);

      exception
         when others =>
            if Is_Open (Dep_File) then
               Close (Dep_File);
            end if;
      end;

      Report_Status (Archive_Built => True, Archive_Exists => True);
   end Build_Global_Archive;

   ---------------------
   -- Display_Command --
   ---------------------

   procedure Display_Command
     (Arguments : Options_Data;
      Path      : String_Access;
      Ellipse   : Boolean := False)
   is
      Display_Ellipse : Boolean := Ellipse;
   begin
      --  Only display the command in Verbose Mode (-v) or when
      --  not in Quiet Output (no -q).

      if not Opt.Quiet_Output then
         Name_Len := 0;

         if Opt.Verbose_Mode then
            if Opt.Verbosity_Level = Opt.Low then
               Add_Str_To_Name_Buffer
                 (Base_Name (Path.all, Executable_Suffix.all));
            else
               Add_Str_To_Name_Buffer (Path.all);
            end if;

            for Arg of Arguments loop
               if Arg.Displayed then
                  Add_Str_To_Name_Buffer (" ");

                  if Arg.Simple_Name then
                     Add_Str_To_Name_Buffer (Base_Name (Arg.Name));

                  else
                     Add_Str_To_Name_Buffer (Arg.Name);
                  end if;

               elsif Display_Ellipse then
                  Add_Str_To_Name_Buffer (" ...");
                  Display_Ellipse := False;
               end if;
            end loop;

            Put_Line (Name_Buffer (1 .. Name_Len));
         end if;
      end if;
   end Display_Command;

   ------------------------
   -- Add_Linker_Options --
   ------------------------

   procedure Add_Linker_Options
     (Arguments   : in out Options_Data;
      For_Project : Project_Id)
   is
      Linker_Lib_Dir_Option  : String_Access;
      Linker_Opts            : Linker_Options_Vector.Vector;
      --  Table to store the Linker'Linker_Options in the project files

      procedure Recursive_Add
        (Proj  : Project_Id;
         Tree  : Project_Tree_Ref;
         Dummy : in out Boolean);
      --  The recursive routine used to add linker options

      -------------------
      -- Recursive_Add --
      -------------------

      procedure Recursive_Add
        (Proj  : Project_Id;
         Tree  : Project_Tree_Ref;
         Dummy : in out Boolean)
      is
         pragma Unreferenced (Dummy);
         Linker_Package : Package_Id;
         Options        : Variable_Value;

      begin
         if Proj /= For_Project then
            Linker_Package :=
              GPR.Util.Value_Of
                (Name        => Name_Linker,
                 In_Packages => Proj.Decl.Packages,
                 Shared      => Tree.Shared);
            Options :=
              GPR.Util.Value_Of
                (Name                    => Name_Ada,
                 Index                   => 0,
                 Attribute_Or_Array_Name => Name_Linker_Options,
                 In_Package              => Linker_Package,
                 Shared                  => Tree.Shared);

            --  If attribute is present, add the project with
            --  the attribute to table Linker_Opts.

            if Options /= Nil_Variable_Value then
               Linker_Opts.Append
                 (Linker_Options_Data'
                    (Project => Proj, Options => Options.Values));
            end if;
         end if;
      end Recursive_Add;

      procedure For_All_Projects is
        new For_Every_Project_Imported (Boolean, Recursive_Add);

      Dummy : Boolean := False;

      --  Start of processing for Get_Linker_Options

   begin
      if For_Project.Config.Linker_Lib_Dir_Option = No_Name then
         Linker_Lib_Dir_Option := new String'("-L");

      else
         Linker_Lib_Dir_Option :=
           new String'
             (Get_Name_String (For_Project.Config.Linker_Lib_Dir_Option));
      end if;

      Linker_Opts.Clear;

      For_All_Projects
        (For_Project, Project_Tree, Dummy, Imported_First => True);

      for Index in reverse 1 .. Linker_Opts.Last_Index loop
         declare
            Options  : String_List_Id := Linker_Opts (Index).Options;
            Proj     : constant Project_Id := Linker_Opts (Index).Project;
            Option   : Name_Id;
            Dir_Path : constant String :=
                         Get_Name_String (Proj.Directory.Display_Name);

         begin
            while Options /= Nil_String loop
               Option :=
                 Project_Tree.Shared.String_Elements.Table (Options).Value;
               Get_Name_String (Option);

               --  Do not consider empty linker options

               if Name_Len /= 0 then
                  --  Object files and -L switches specified with relative
                  --  paths must be converted to absolute paths.

                  if Name_Len > Linker_Lib_Dir_Option'Length
                    and then
                      Name_Buffer (1 .. Linker_Lib_Dir_Option'Length) =
                        Linker_Lib_Dir_Option.all
                  then
                     if Is_Absolute_Path
                       (Name_Buffer
                          (Linker_Lib_Dir_Option'Length + 1 .. Name_Len))
                     then
                        Add_Argument
                          (Arguments, Name_Buffer (1 .. Name_Len), True);

                     else
                        declare
                           Dir : constant String :=
                             Dir_Path &
                             Directory_Separator &
                             Name_Buffer
                             (Linker_Lib_Dir_Option'Length + 1 .. Name_Len);
                        begin
                           if Is_Directory (Dir) then
                              Add_Argument
                                (Arguments,
                                 Linker_Lib_Dir_Option.all & Dir,
                                 True);
                           else
                              --  ??? Really ignore the -L switch given by the
                              --  project?
                              Add_Argument
                                (Arguments,
                                 Name_Buffer (1 .. Name_Len),
                                 True);
                           end if;
                        end;
                     end if;

                  elsif Name_Buffer (1) = '-' or else
                      Is_Absolute_Path (Name_Buffer (1 .. Name_Len))
                  then
                     Add_Argument
                       (Arguments, Name_Buffer (1 .. Name_Len), True);

                  else
                     declare
                        File : constant String :=
                          Dir_Path &
                          Directory_Separator &
                          Name_Buffer (1 .. Name_Len);
                     begin
                        if Is_Regular_File (File) then
                           Add_Argument
                             (Arguments, File, True, Simple_Name => True);
                        else
                           Add_Argument
                             (Arguments, Name_Buffer (1 .. Name_Len), True);
                        end if;
                     end;
                  end if;
               end if;

               Options :=
                 Project_Tree.Shared.String_Elements.Table (Options).Next;
            end loop;
         end;
      end loop;
   end Add_Linker_Options;

   ---------------------------
   -- Is_In_Library_Project --
   ---------------------------

   function Is_In_Library_Project (Object_Path : String) return Boolean is
      Path_Id : constant Path_Name_Type := Create_Name (Object_Path);
      Src     : Source_Id;
      Iter    : Source_Iterator;
   begin
      Iter := For_Each_Source (Project_Tree);
      loop
         Src := GPR.Element (Iter);
         exit when Src = No_Source;

         if Src.Object_Path = Path_Id then
            return Src.Project.Library;
         end if;

         Next (Iter);
      end loop;

      return False;
   end Is_In_Library_Project;

   ------------------------
   -- Rpaths_Relative_To --
   ------------------------

   procedure Rpaths_Relative_To
     (Rpaths   : in out String_Vectors.Vector;
      Exec_Dir : Path_Name_Type;
      Origin   : Name_Id)
   is
      Origin_Name : constant String := Get_Name_String (Origin);
      Exec        : constant String := Get_Name_String (Exec_Dir);
      Ret         : String_Vectors.Vector;

   begin
      for Path of Rpaths loop
         Ret.Append (Relative_RPath (Path, Exec, Origin_Name));
      end loop;

      Rpaths := Ret;
   end Rpaths_Relative_To;

   ---------------
   -- Link_Main --
   ---------------

   procedure Link_Main (Main_File : in out Main_Info) is

      function Global_Archive_Name (For_Project : Project_Id) return String;
      --  Returns the name of the global archive for a project

      procedure Add_Run_Path_Options;
      --  Add the run path option switch. if there is one

      procedure Remove_Duplicated_Specs (Arguments : in out Options_Data);
      --  Remove duplicated --specs=... options from Arguments,
      --  keep right-most.

      procedure Remove_Duplicated_T (Arguments : in out Options_Data);
      --  Remove duplicated -T[ ]<linker script> options from Arguments,
      --  keep left-most.

      procedure Load_Bindfile_Option_Substitution;
      --  Load all Bindfile_Option_Substitution attributes into
      --  Bindfile_Option_Substitution container.

      function Apply_Bindfile_Option_Substitution
        (Option : String) return Boolean;
      --  Append string list from Bindfile_Option_Substitution (Option) into
      --  Binding_Options.

      procedure Add_To_Other_Arguments (A : String) with Inline;
      --  Add argument to Other_Arguments

      package String_Values is new Ada.Containers.Indefinite_Hashed_Maps
        (String, String_List_Id, Ada.Strings.Hash, "=");

      Bindfile_Option_Substitution : String_Values.Map;

      Were_Options : String_Sets.Set;
      --  Keep options already included

      Linker_Name     : String_Access := null;
      Linker_Path     : String_Access;
      Min_Linker_Opts : Name_List_Index;
      Exchange_File   : Text_IO.File_Type;
      Line            : String (1 .. 1_000);
      Last            : Natural;

      Section : Binding_Section := No_Binding_Section;

      Linker_Needs_To_Be_Called : Boolean;

      Executable_TS      : Time;
      Main_Object_TS     : Time;
      Binder_Exchange_TS : Time;
      Binder_Object_TS   : Time := Time_Of (2000, 1, 1);
      Global_Archive_TS  : Time;

      function File_Stamp (File : Path_Name_Type) return Time is
        (File_Time_Stamp (Get_Name_String (File)));
      --  Returns file modification time

      Global_Archive_Has_Been_Built : Boolean;
      Global_Archive_Exists         : Boolean;
      OK                            : Boolean;

      Disregard          : Boolean;

      B_Data : Binding_Data;

      --  Main already has the right canonical casing
      Main         : constant String := Get_Name_String (Main_File.File);
      Main_Source  : constant Source_Id := Main_File.Source;

      Main_Id        : File_Name_Type;

      Exec_Name      : File_Name_Type;
      Exec_Path_Name : Path_Name_Type;

      Main_Proj      : Project_Id;

      Main_Base_Name_Index : File_Name_Type;

      Index_Separator : Character;

      Response_File_Name : Path_Name_Type := No_Path;
      Response_2         : Path_Name_Type := No_Path;

      Rpaths             : String_Vectors.Vector;

      Binding_Options    : String_Vectors.Vector;
      --  Table to store the linking options coming from the binder

      Arguments          : Options_Data;
      Objects            : String_Vectors.Vector;
      Other_Arguments    : Options_Data;

      Linking_With_Static_SALs : Boolean := False;

      --------------------------
      -- Add_Run_Path_Options --
      --------------------------

      procedure Add_Run_Path_Options is
         Nam_Nod : Name_Node;
         Length  : Natural := 0;
         Arg     : String_Access := null;
      begin
         for Path of Path_Options loop
            Add_Rpath (Rpaths, Path);
            Add_Rpath (Rpaths, Shared_Libgcc_Dir (Path));
         end loop;

         if Rpaths.Is_Empty then
            return;
         end if;

         if Main_Proj.Config.Run_Path_Origin /= No_Name
           and then Get_Name_String (Main_Proj.Config.Run_Path_Origin) /= ""
         then
            Rpaths_Relative_To
              (Rpaths,
               Main_Proj.Exec_Directory.Display_Name,
               Main_Proj.Config.Run_Path_Origin);
         end if;

         if Main_Proj.Config.Separate_Run_Path_Options then
            for Path of Rpaths loop
               Nam_Nod := Main_File.Tree.Shared.Name_Lists.Table
                 (Main_Proj.Config.Run_Path_Option);
               while Nam_Nod.Next /= No_Name_List loop
                  Add_To_Other_Arguments (Get_Name_String (Nam_Nod.Name));
                  Nam_Nod := Main_File.Tree.Shared.Name_Lists.Table
                    (Nam_Nod.Next);
               end loop;

               Get_Name_String (Nam_Nod.Name);
               Add_Str_To_Name_Buffer (Path);
               Add_To_Other_Arguments (Name_Buffer (1 .. Name_Len));
            end loop;

         else
            Nam_Nod := Main_File.Tree.Shared.Name_Lists.Table
              (Main_Proj.Config.Run_Path_Option);

            while Nam_Nod.Next /= No_Name_List loop
               Add_To_Other_Arguments (Get_Name_String (Nam_Nod.Name));
               Nam_Nod := Main_File.Tree.Shared.Name_Lists.Table
                 (Nam_Nod.Next);
            end loop;

            --  Compute the length of the argument

            Get_Name_String (Nam_Nod.Name);
            Length := Name_Len;

            for Path of Rpaths loop
               Length := Length + Path'Length + 1;
            end loop;

            --  Create the argument

            Arg := new String (1 .. Length);
            Length := Name_Len;
            Arg (1 .. Name_Len) := Name_Buffer (1 .. Name_Len);

            for Path of Rpaths loop
               Arg (Length + 1 .. Length + Path'Length) := Path;
               Length := Length + Path'Length + 1;
               Arg (Length) := ':';
            end loop;

            Add_To_Other_Arguments (Arg (1 .. Arg'Last - 1));
         end if;
      end Add_Run_Path_Options;

      ----------------------------
      -- Add_To_Other_Arguments --
      ----------------------------

      procedure Add_To_Other_Arguments (A : String) is
      begin
         Add_Argument (Other_Arguments, A, Opt.Verbose_Mode);
      end Add_To_Other_Arguments;

      -------------------------
      -- Global_Archive_Name --
      -------------------------

      function Global_Archive_Name (For_Project : Project_Id) return String is
      begin
         return
           "lib" & Get_Name_String (For_Project.Name) &
           Archive_Suffix (For_Project);
      end Global_Archive_Name;

      ---------------------------------------
      -- Load_Bindfile_Option_Substitution --
      ---------------------------------------

      procedure Load_Bindfile_Option_Substitution is
         The_Array : Array_Element_Id;
         Element   : Array_Element;

         Shared : Shared_Project_Tree_Data_Access renames Project_Tree.Shared;
         Binder : constant Package_Id :=
                    Value_Of
                      (Name_Binder, Main_File.Project.Decl.Packages, Shared);
      begin
         The_Array :=
           Value_Of
             (Name      => Name_Bindfile_Option_Substitution,
              In_Arrays => Shared.Packages.Table (Binder).Decl.Arrays,
              Shared    => Shared);

         while The_Array /= No_Array_Element loop
            Element := Shared.Array_Elements.Table (The_Array);
            Bindfile_Option_Substitution.Include
              (Get_Name_String (Element.Index), Element.Value.Values);
            The_Array := Element.Next;
         end loop;
      end Load_Bindfile_Option_Substitution;

      ----------------------------------------
      -- Apply_Bindfile_Option_Substitution --
      ----------------------------------------

      function Apply_Bindfile_Option_Substitution
        (Option : String) return Boolean
      is
         CV : constant String_Values.Cursor :=
                Bindfile_Option_Substitution.Find (Option);
         Values  : String_List_Id;
         Pointer : access String_Element;
      begin
         if not String_Values.Has_Element (CV) then
            return False;
         end if;

         Values := String_Values.Element (CV);

         while Values /= Nil_String loop
            Pointer :=
              Project_Tree.Shared.String_Elements.Table
                (Values)'Unrestricted_Access;
            Binding_Options.Append (Get_Name_String (Pointer.Value));
            Values := Pointer.Next;
         end loop;

         return True;
      end Apply_Bindfile_Option_Substitution;

      -----------------------------
      -- Remove_Duplicated_Specs --
      -----------------------------

      procedure Remove_Duplicated_Specs (Arguments : in out Options_Data) is
         Position : String_Sets.Cursor;
         Inserted : Boolean;
      begin
         for Index in reverse 1 .. Arguments.Last_Index loop
            declare
               Arg : constant String := Arguments (Index).Name;
            begin
               if Arg'Length >= 8 and then Arg (1 .. 8) = "--specs=" then
                  Were_Options.Insert (Arg, Position, Inserted);

                  if not Inserted then
                     Arguments.Delete (Index);
                  end if;
               end if;
            end;
         end loop;
      end Remove_Duplicated_Specs;

      -------------------------
      -- Remove_Duplicated_T --
      -------------------------

      procedure Remove_Duplicated_T (Arguments : in out Options_Data) is
         Position  : String_Sets.Cursor;
         Inserted  : Boolean;
         Arg_Index : Positive := Arguments.First_Index;
      begin
         while Arg_Index <= Arguments.Last_Index loop
            declare
               Arg1 : constant String := Arguments (Arg_Index).Name;
            begin
               if Arg1'Length >= 2 and then Arg1 (1 .. 2) = "-T" then
                  --  Case of -T and <file> as separate arguments
                  --  (from .cgpr file)

                  if Arg1'Length = 2 then
                     if Arg_Index < Arguments.Last_Index then
                        declare
                           Arg2 : constant String :=
                                    Arguments (Arg_Index + 1).Name;
                        begin
                           Were_Options.Insert
                             (Arg1 & Arg2, Position, Inserted);

                           if Inserted then
                              Arg_Index := Arg_Index + 2;
                           else
                              Arguments.Delete (Arg_Index, 2);
                           end if;
                        end;

                     else
                        --  We get here if the link command somehow ends
                        --  with "-T" which would indicate a bug.
                        --  Just ignore it now and let the linker fail.
                        Arg_Index := Arg_Index + 1;
                     end if;

                  --  Case of "-T<file>" (from SAL linker options)
                  else
                     Were_Options.Insert (Arg1, Position, Inserted);

                     if Inserted then
                        Arg_Index := Arg_Index + 1;
                     else
                        Arguments.Delete (Arg_Index);
                     end if;
                  end if;

               else
                  Arg_Index := Arg_Index + 1;
               end if;
            end;
         end loop;
      end Remove_Duplicated_T;

   begin
      --  Make sure that the table Rpaths is emptied after each main, so
      --  that the same rpaths are not duplicated.

      Path_Options.Clear;

      Linker_Needs_To_Be_Called := Opt.Force_Compilations;

      Main_Id := Create_Name (Base_Name (Main));
      Main_Proj := Ultimate_Extending_Project_Of (Main_Source.Project);

      Change_To_Object_Directory (Main_Proj);

      --  Build the global archive for this project, if needed

      Build_Global_Archive
        (Main_Proj,
         Main_File.Tree,
         Global_Archive_Has_Been_Built,
         Global_Archive_Exists,
         Main_File.Command,
         OK);

      if not OK then
         Stop_Spawning := True;
         Bad_Processes.Append (Main_File);
         return;
      end if;

      Main_File.Command.Clear;

      --  Get the main base name

      Index_Separator :=
        Main_Source.Language.Config.Multi_Unit_Object_Separator;

      Main_Base_Name_Index :=
        Base_Name_Index_For (Main, Main_File.Index, Index_Separator);

      if not Linker_Needs_To_Be_Called and then
        Opt.Verbosity_Level > Opt.Low
      then
         Put ("   Checking executable for ");
         Put (Get_Name_String (Main_Source.File));
         Put_Line (" ...");
      end if;

      if Output_File_Name /= null then
         Set_Name_Buffer (Output_File_Name.all);

         --  If an executable name was specified without an extension and
         --  there is a non empty executable suffix, add the suffix to the
         --  executable name.

         if Main_Proj.Config.Executable_Suffix not in No_Name | Empty_String
         then
            declare
               Suffix : String := Get_Name_String
                 (Main_Proj.Config.Executable_Suffix);
               File_Name : String := Output_File_Name.all;

            begin
               if Index (File_Name, ".") = 0 then
                  Canonical_Case_File_Name (Suffix);
                  Canonical_Case_File_Name (File_Name);

                  if Name_Len <= Suffix'Length
                    or else File_Name
                      (File_Name'Last - Suffix'Length + 1 .. File_Name'Last)
                    /= Suffix
                  then
                     Add_Str_To_Name_Buffer (Suffix);
                  end if;
               end if;
            end;
         end if;

         Exec_Name := Name_Find;

      else
         Exec_Name := Executable_Of
           (Project  => Main_Proj,
            Shared   => Main_File.Tree.Shared,
            Main     => Main_Id,
            Index    => Main_Source.Index,
            Language => Get_Name_String (Main_Source.Language.Name));
      end if;

      if Main_Proj.Exec_Directory = Main_Proj.Object_Directory
        or else Is_Absolute_Path (Get_Name_String (Exec_Name))
      then
         Exec_Path_Name := Path_Name_Type (Exec_Name);

      else
         Get_Name_String (Main_Proj.Exec_Directory.Display_Name);
         Add_Char_To_Name_Buffer (Directory_Separator);
         Get_Name_String_And_Append (Exec_Name);
         Exec_Path_Name := Name_Find;
      end if;

      Executable_TS := File_Stamp (Exec_Path_Name);

      if not Linker_Needs_To_Be_Called
        and then Executable_TS = Osint.Invalid_Time
      then
         Linker_Needs_To_Be_Called := True;

         if Opt.Verbosity_Level > Opt.Low then
            Put_Line ("      -> executable does not exist");
         end if;
      end if;

      --  Get the path of the linker driver

      if Main_Proj.Config.Linker /= No_Path then
         Linker_Name := new String'(Get_Name_String (Main_Proj.Config.Linker));

         Linker_Path := Locate_Exec_On_Path (Linker_Name.all);

         if Linker_Path = null then
            Fail_Program
              (Main_File.Tree,
               "unable to find linker " & Linker_Name.all);
         end if;

      else
         Fail_Program
           (Main_File.Tree,
            "no linker specified and no default linker in the configuration",
            Exit_Code => E_General);
      end if;

      Initialize_Source_Record (Main_Source);

      Main_Object_TS := File_Stamp (Main_Source.Object_Path);

      if not Linker_Needs_To_Be_Called then
         if Main_Object_TS = Osint.Invalid_Time then
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line ("      -> main object does not exist");
            end if;

            Linker_Needs_To_Be_Called := True;

         elsif Main_Object_TS > Executable_TS then
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line
                 ("      -> main object more recent than executable");
            end if;

            Linker_Needs_To_Be_Called := True;
         end if;
      end if;

      if Main_Object_TS = Osint.Invalid_Time then
         Put ("main object for ");
         Put (Get_Name_String (Main_Source.File));
         Put_Line (" does not exist");
         Record_Failure (Main_File);
         return;
      end if;

      --  Add the Leading_Switches if there are any in package Linker

      declare
         The_Packages   : constant Package_Id := Main_Proj.Decl.Packages;
         Linker_Package : constant GPR.Package_Id :=
                            GPR.Util.Value_Of
                              (Name        => Name_Linker,
                               In_Packages => The_Packages,
                               Shared      => Main_File.Tree.Shared);

         Switches    : Variable_Value;
         Switch_List : String_List_Id;
         Element     : String_Element;

      begin
         if Linker_Package /= No_Package then
            declare
               Switches_Array : constant Array_Element_Id :=
                                  GPR.Util.Value_Of
                                    (Name      => Name_Leading_Switches,
                                     In_Arrays =>
                                       Main_File.Tree.Shared.Packages.Table
                                         (Linker_Package).Decl.Arrays,
                                     Shared    => Main_File.Tree.Shared);

            begin
               Switches :=
                 GPR.Util.Value_Of
                   (Index     => Name_Id (Main_Id),
                    Src_Index => 0,
                    In_Array  => Switches_Array,
                    Shared    => Main_File.Tree.Shared);

               if Switches = Nil_Variable_Value then
                  Switches :=
                    GPR.Util.Value_Of
                      (Index                  =>
                           Main_Source.Language.Name,
                       Src_Index              => 0,
                       In_Array               => Switches_Array,
                       Shared                 => Main_File.Tree.Shared,
                       Force_Lower_Case_Index => True);
               end if;

               if Switches = Nil_Variable_Value then
                  Switches :=
                    GPR.Util.Value_Of
                      (Index                  => All_Other_Names,
                       Src_Index              => 0,
                       In_Array               => Switches_Array,
                       Shared                 => Main_File.Tree.Shared,
                       Force_Lower_Case_Index => True);
               end if;

               case Switches.Kind is
                  when Undefined | Single =>
                     null;

                  when GPR.List =>
                     Switch_List := Switches.Values;

                     while Switch_List /= Nil_String loop
                        Element :=
                          Main_File.Tree.Shared.String_Elements.Table
                            (Switch_List);
                        Get_Name_String (Element.Value);

                        if Name_Len > 0 then
                           Add_Argument
                             (Arguments, Name_Buffer (1 .. Name_Len), True);
                        end if;

                        Switch_List := Element.Next;
                     end loop;
               end case;
            end;
         end if;
      end;

      Add_Argument
        (Arguments,
         Get_Name_String
           (if Main_Proj = Main_Source.Object_Project
            then Name_Id (Main_Source.Object)
            else Name_Id (Main_Source.Object_Path)),
         True);

      Find_Binding_Languages (Main_File.Tree, Main_File.Project);

      --  Build the objects list

      if Builder_Data (Main_File.Tree).There_Are_Binder_Drivers then
         Binding_Options.Clear;

         B_Data := Builder_Data (Main_File.Tree).Binding;

         Binding_Loop :
         while B_Data /= null loop
            declare
               Exchange_File_Name : constant String :=
                                      Binder_Exchange_File_Name
                                        (Main_Base_Name_Index,
                                         B_Data.Binder_Prefix).all;
               Binding_Not_Necessary : Boolean;

            begin
               if Is_Regular_File (Exchange_File_Name) then

                  Binder_Exchange_TS :=
                    File_Stamp
                      (Path_Name_Type'(Create_Name
                       (Exchange_File_Name)));

                  Open (Exchange_File, In_File, Exchange_File_Name);
                  Get_Line (Exchange_File, Line, Last);
                  Binding_Not_Necessary :=
                    Line (1 .. Last) = Binding_Label (Nothing_To_Bind);
                  Close (Exchange_File);

                  if Binding_Not_Necessary then
                     goto No_Binding;
                  end if;

                  if not Linker_Needs_To_Be_Called
                    and then Binder_Exchange_TS > Executable_TS
                  then
                     Linker_Needs_To_Be_Called := True;

                     if Opt.Verbosity_Level > Opt.Low then
                        Put ("      -> binder exchange file """);
                        Put (Exchange_File_Name);
                        Put_Line (""" is more recent than executable");
                     end if;
                  end if;

                  Load_Bindfile_Option_Substitution;

                  Open (Exchange_File, In_File, Exchange_File_Name);

                  while not End_Of_File (Exchange_File) loop
                     Get_Line (Exchange_File, Line, Last);

                     if Last > 0 then
                        if Line (1) = '[' then
                           Section := Get_Binding_Section (Line (1 .. Last));

                        else
                           case Section is
                              when Generated_Object_File =>

                                 Binder_Object_TS :=
                                   File_Stamp
                                     (Path_Name_Type'
                                        (Create_Name (Line (1 .. Last))));

                                 Objects.Append (Line (1 .. Last));

                              when Bound_Object_Files =>
                                 if Normalize_Pathname
                                  (Line (1 .. Last),
                                   Resolve_Links => Opt.Follow_Links_For_Files,
                                   Case_Sensitive => False) /=
                                   Normalize_Pathname
                                   (Get_Name_String (Main_Source.Object_Path),
                                   Resolve_Links => Opt.Follow_Links_For_Files,
                                   Case_Sensitive => False)
                                   and then
                                     not Is_In_Library_Project
                                       (Line (1 .. Last))
                                 then
                                    Objects.Append (Line (1 .. Last));
                                 end if;

                              when Resulting_Options =>
                                 if not Apply_Bindfile_Option_Substitution
                                          (Line (1 .. Last))
                                 then
                                    Binding_Options.Append (Line (1 .. Last));
                                 end if;

                              when Gprexch.Run_Path_Option =>
                                 if Opt.Run_Path_Option
                                   and then
                                     Main_Proj.Config.Run_Path_Option /=
                                       No_Name_List
                                 then
                                    Path_Options.Append (Line (1 .. Last));
                                 end if;

                              when others =>
                                 null;
                           end case;
                        end if;
                     end if;
                  end loop;

                  Close (Exchange_File);

                  if Binder_Object_TS = Osint.Invalid_Time then
                     if not Linker_Needs_To_Be_Called
                       and then Opt.Verbosity_Level > Opt.Low
                     then
                        Put_Line
                          ("      -> no binder generated object file");
                     end if;

                     Put ("no binder generated object file for ");
                     Put_Line (Get_Name_String (Main_File.File));
                     Record_Failure (Main_File);
                     return;

                  elsif not Linker_Needs_To_Be_Called
                    and then Binder_Object_TS > Executable_TS
                  then
                     Linker_Needs_To_Be_Called := True;

                     if Opt.Verbosity_Level > Opt.Low then
                        Put_Line
                          ("      -> binder generated object is more " &
                             "recent than executable");
                     end if;
                  end if;

               else
                  Put ("binder exchange file ");
                  Put (Exchange_File_Name);
                  Put_Line (" does not exist");
                  Record_Failure (Main_File);
                  return;
               end if;
            end;

            <<No_Binding>>
            B_Data := B_Data.Next;
         end loop Binding_Loop;
      end if;

      --  Add object files for unconditionally linked languages

      declare
         Lang : Language_Ptr := Main_Proj.Languages;
         Src  : Source_Id;
      begin
         while Lang /= No_Language_Index loop
            if Lang.Unconditional_Linking then
               Src := Lang.First_Source;

               while Src /= No_Source loop
                  Objects.Append (Get_Name_String (Src.Object_Path));
                  Src := Src.Next_In_Lang;
               end loop;
            end if;

            Lang := Lang.Next;
         end loop;
      end;

      --  Add the global archive, if there is one

      if Global_Archive_Exists then
         Global_Archive_TS :=
           File_Stamp
             (Path_Name_Type'
                  (Create_Name (Global_Archive_Name (Main_Proj))));

         if Global_Archive_TS = Osint.Invalid_Time then
            if not Linker_Needs_To_Be_Called
              and then Opt.Verbosity_Level > Opt.Low
            then
               Put_Line ("      -> global archive does not exist");
            end if;

            Put ("global archive for project file ");
            Put (Get_Name_String (Main_Proj.Name));
            Put_Line (" does not exist");
         end if;
      end if;

      if not Linker_Needs_To_Be_Called
        and then Global_Archive_Has_Been_Built
      then
         Linker_Needs_To_Be_Called := True;

         if Opt.Verbosity_Level > Opt.Low then
            Put_Line ("      -> global archive has just been built");
         end if;
      end if;

      if not Linker_Needs_To_Be_Called
        and then Global_Archive_Exists
        and then Global_Archive_TS > Executable_TS
      then
         Linker_Needs_To_Be_Called := True;

         if Opt.Verbosity_Level > Opt.Low then
            Put_Line
              ("      -> global archive is more recent than executable");
         end if;
      end if;

      --  Check if there are library files that are more recent than
      --  executable.

      declare
         List : Project_List := Main_Proj.All_Imported_Projects;
         Proj : Project_Id;
      begin
         while List /= null loop
            Proj := List.Project;
            List := List.Next;

            if Proj.Extended_By = No_Project
              and then Proj.Library
              and then Proj.Object_Directory /= No_Path_Information
              and then (Is_Static (Proj)
                        or else Proj.Standalone_Library = No)
            then
               --  Put the full path name of the library file in Name_Buffer

               Get_Name_String (Proj.Library_Dir.Display_Name);

               if Is_Static (Proj) then
                  Add_Str_To_Name_Buffer ("lib");
                  Get_Name_String_And_Append (Proj.Library_Name);

                  if Proj.Config.Archive_Suffix = No_File then
                     Add_Str_To_Name_Buffer (".a");
                  else
                     Get_Name_String_And_Append (Proj.Config.Archive_Suffix);
                  end if;

               else
                  --  Shared libraries

                  if Proj.Config.Shared_Lib_Prefix = No_File then
                     Add_Str_To_Name_Buffer ("lib");
                  else
                     Get_Name_String_And_Append
                       (Proj.Config.Shared_Lib_Prefix);
                  end if;

                  Get_Name_String_And_Append (Proj.Library_Name);

                  if Proj.Config.Shared_Lib_Suffix = No_File then
                     Add_Str_To_Name_Buffer (".so");
                  else
                     Get_Name_String_And_Append
                       (Proj.Config.Shared_Lib_Suffix);
                  end if;
               end if;

               --  Check that library file exists and that it is not more
               --  recent than the executable.

               declare
                  Lib_TS : constant Time :=
                             File_Time_Stamp (Name_Buffer (1 .. Name_Len));
               begin
                  if Lib_TS = Osint.Invalid_Time then
                     Linker_Needs_To_Be_Called := True;

                     if Opt.Verbosity_Level > Opt.Low then
                        Put ("      -> library file """);
                        Put (Name_Buffer (1 .. Name_Len));
                        Put_Line (""" not found");
                     end if;

                     exit;

                  elsif Lib_TS > Executable_TS then
                     Linker_Needs_To_Be_Called := True;

                     if Opt.Verbosity_Level > Opt.Low then
                        Put ("      -> library file """);
                        Put (Name_Buffer (1 .. Name_Len));
                        Put_Line (""" is more recent than executable");
                     end if;

                     exit;
                  end if;
               end;
            end if;
         end loop;
      end;

      if not Linker_Needs_To_Be_Called then
         if Opt.Verbosity_Level > Opt.Low then
            Put_Line ("      -> up to date");

         elsif not Opt.Quiet_Output then
            Inform (Exec_Name, "up to date");
         end if;

      else
         if Global_Archive_Exists then
            Add_To_Other_Arguments (Global_Archive_Name (Main_Proj));
         end if;

         --  Add the library switches, if there are libraries

         Process_Imported_Libraries (Main_Proj, There_Are_SALs => Disregard);

         Library_Dirs.Reset;

         for J in reverse 1 .. Library_Projs.Last_Index loop
            if not Library_Projs (J).Is_Aggregated then
               if Is_Static (Library_Projs (J).Proj) then
                  declare
                     Proj     : constant Project_Id := Library_Projs (J).Proj;
                     Lib_Name : constant String :=
                                  Get_Name_String (Proj.Library_Name);
                     Lib_Path : constant String :=
                                  Get_Name_String
                                    (Proj.Library_Dir.Display_Name)
                                  & "lib" & Lib_Name & Archive_Suffix (Proj);
                     Arg_List : Argument_List_Access;
                     Arg_Disp : Options_Data;

                     procedure Fill_Options_Data_From_Arg_List_Access
                       (ALA : Argument_List_Access; OD : out Options_Data);
                     --  Fill an Options_Data structure (used by
                     --  Display_Command) from an Argument_List_Access
                     --  structure (used by the various spawning utilities).
                     --  The Options_Data object is cleared first.

                     procedure Fill_Options_Data_From_Arg_List_Access
                       (ALA : Argument_List_Access; OD : out Options_Data) is
                     begin
                        OD.Clear;
                        for A of ALA.all loop
                           Add_Argument (OD, A.all, Opt.Verbose_Mode);
                        end loop;
                     end Fill_Options_Data_From_Arg_List_Access;

                  begin
                     Add_To_Other_Arguments (Lib_Path);

                     --  Extract linker switches in the case of a static SAL

                     if Proj.Standalone_Library /= No then
                        Linking_With_Static_SALs := True;

                        if Archive_Builder_Path = null then
                           Check_Archive_Builder;
                        end if;

                        declare
                           Status : aliased Integer;
                           Output : String_Access;
                           EOL    : constant String := "" & ASCII.LF;

                           Obj           : String_Access;
                           Obj_Path_Name : Path_Name_Type;

                           Objdump_Exec : String_Access;
                           AB_Path      : constant String :=
                             Archive_Builder_Path.all;
                           AB_Path_Last : Natural := 0;

                           File         : Text_File;
                           Lib_Dir_Name : Path_Name_Type;

                           FD       : File_Descriptor;
                           Tmp_File : Path_Name_Type;
                           Success  : Boolean := True;

                           procedure Set_Tmp_File_Line;
                           --  Set Tmp_File first line to Error

                           procedure Decode_Line;
                           --  Decode line from File to Name_Buffer

                           -----------------------
                           -- Set_Tmp_File_Line --
                           -----------------------

                           procedure Set_Tmp_File_Line is
                              File : File_Type;
                           begin
                              Open (File, In_File, Get_Name_String (Tmp_File));

                              declare
                                 Line : constant String := Get_Line (File);
                              begin
                                 Error_Msg_Strlen := Line'Length;
                                 Error_Msg_String (1 .. Line'Length) := Line;
                              end;

                              Close (File);
                           end Set_Tmp_File_Line;

                           Line  : String (1 .. 128);
                           First : Positive := 42;
                           Last  : Natural  := 1;

                           -----------------
                           -- Decode_Line --
                           -----------------

                           procedure Decode_Line is

                              function Is_Hex
                                (Str : String) return Boolean
                              is
                                (for all Char of Str =>
                                    Char in '0' .. '9' | 'a' .. 'f');

                           begin
                              Name_Len := 0;

                              Decoding : loop
                                 if First > 41 then
                                    loop
                                       exit Decoding when End_Of_File (File);
                                       Get_Line (File, Line, Last);
                                       exit when Last > 43
                                         and then Is_Hex (Line (2 .. 4))
                                         and then Is_Hex (Line (7 .. 8))
                                         and then
                                           (for all J in 9 .. 41 =>
                                              Line (J) in ' ' | '0' .. '9'
                                                  | 'a' .. 'f')
                                         and then Line (1) = ' '
                                         and then Line (5 .. 6) = "0 "
                                         and then Line (15) = ' '
                                         and then Line (24) = ' '
                                         and then Line (33) = ' '
                                         and then Line (42 .. 43) = "  ";
                                    end loop;
                                    First := 7;
                                 end if;

                                 while First < 42 loop
                                    Name_Len := Name_Len + 1;
                                    Name_Buffer (Name_Len) :=
                                      Character'Val
                                        (Integer'Value
                                           ("16#" & Line (First .. First + 1)
                                            & '#'));
                                    First := First + 2;
                                    if Line (First) = ' ' then
                                       First := First + 1;

                                       if Line (First) = ' '
                                         and then First < 42
                                       then
                                          pragma Assert
                                            (End_Of_File (File),
                                             "not at end of file "
                                             & Line (1 .. Last) & First'Img);
                                          First := 42;
                                       end if;
                                    end if;

                                    if Name_Buffer (Name_Len) = ASCII.LF then
                                       Name_Len := Name_Len - 1;
                                       if Name_Buffer (Name_Len) = ASCII.CR
                                       then
                                          Name_Len := Name_Len - 1;
                                       end if;
                                       exit Decoding;
                                    end if;
                                 end loop;
                              end loop Decoding;
                           end Decode_Line;

                        begin
                           --  Create the temporary file to receive (and
                           --  discard) the output from spawned processes.

                           Tempdir.Create_Temp_File (FD, Tmp_File);

                           if FD = Invalid_FD then
                              Fail_Program
                                (Main_File.Tree,
                                 "could not create temporary file");
                           else
                              Record_Temp_File
                                (Main_File.Tree.Shared, Tmp_File);
                           end if;

                           --  Use the archive builder path to compute the
                           --  path to objdump.

                           if AB_Path'Length > 2
                             and then
                               AB_Path (AB_Path'Last - 1 .. AB_Path'Last)
                               = "ar"
                           then
                              AB_Path_Last := AB_Path'Last - 2;

                           elsif AB_Path'Length > 6
                             and then
                               AB_Path (AB_Path'Last - 5 .. AB_Path'Last)
                               = "ar.exe"
                           then
                              AB_Path_Last := AB_Path'Last - 6;
                           end if;

                           Objdump_Exec :=
                              Locate_Exec_On_Path
                                 (AB_Path (1 .. AB_Path_Last) & "objdump");

                           --  If objdump is not found this way, try with
                           --  the one from the system.

                           if Objdump_Exec = null then
                              Objdump_Exec := Locate_Exec_On_Path ("objdump");
                           end if;

                           --  If still not found, warn and jump away

                           if Objdump_Exec = null then
                              Error_Msg
                                 ("?unable to locate objdump", GPR.No_Location);
                              goto Linker_Options_Incomplete;
                           end if;

                           --  List the archive content

                           Arg_List := new GNAT.Strings.String_List'
                             (1 => new String'("-t"),
                              2 => new String'(Lib_Path));

                           Fill_Options_Data_From_Arg_List_Access
                             (Arg_List, Arg_Disp);
                           Display_Command (Arg_Disp, Archive_Builder_Path);

                           Output := new String'
                             (GNAT.Expect.Get_Command_Output
                                (Command    => Archive_Builder_Path.all,
                                 Arguments  => Arg_List.all,
                                 Input      => "",
                                 Status     => Status'Access,
                                 Err_To_Out => True));

                           Free (Arg_List);

                           if Status /= 0 then
                              --  Warning if the archive builder failed

                              Error_Msg_Strlen := Output'Length;
                              Error_Msg_String (1 .. Output'Length) :=
                                Output.all;
                              Error_Msg
                                ("?list of archive content failed: ~",
                                 Proj.Location);
                              Free (Output);

                              goto Linker_Options_Incomplete;
                           end if;

                           --  Search through the object files list for the
                           --  expected binder-generated ones.

                           declare
                              Lines : constant Name_Array_Type :=
                                        Split (Output.all, EOL);
                              Lib_Fn : constant String :=
                                         Canonical_Case_File_Name (Lib_Name);
                              PP     : constant String :=
                                         Partial_Prefix & Lib_Fn & "_";
                           begin
                              Free (Output);

                              for L of Lines loop
                                 Get_Name_String (L);

                                 if On_Windows
                                   and then Name_Buffer (Name_Len) = ASCII.CR
                                 then
                                    --  Skip the final CR

                                    Name_Len := Name_Len - 1;
                                 end if;

                                 Canonical_Case_File_Name
                                   (Name_Buffer (1 .. Name_Len));

                                 if Name_Buffer (1 .. Name_Len) =
                                   "b__" & Lib_Fn & Object_Suffix
                                   or else
                                     (Starts_With
                                        (Name_Buffer (1 .. Name_Len), PP)
                                      and then Is_Object
                                                 (Name_Buffer (1 .. Name_Len))
                                      and then
                                        (for all C of Name_Buffer
                                           (PP'Length + 1
                                            .. Name_Len - Object_Suffix'Length)
                                         => C in '0' .. '9'))
                                 then
                                    Obj := new String'
                                      (Name_Buffer (1 .. Name_Len));
                                    Obj_Path_Name := Name_Find;
                                 end if;
                              end loop;
                           end;

                           if Obj = null then
                              --  Warning if no such object file is found

                              Error_Msg
                                ("?linker options section not found in "
                                 & Lib_Name & ".a, using defaults.",
                                 Proj.Location);

                              goto Linker_Options_Incomplete;
                           end if;

                           --  Extract the object file

                           Arg_List := new GNAT.Strings.String_List'
                             (1 => new String'("-x"),
                              2 => new String'(Lib_Path),
                              3 => new String'(Obj.all));

                           Fill_Options_Data_From_Arg_List_Access
                             (Arg_List, Arg_Disp);
                           Display_Command (Arg_Disp, Archive_Builder_Path);

                           Spawn
                             (Archive_Builder_Path.all, Arg_List.all, FD,
                              Status);

                           Free (Arg_List);

                           if Status /= 0 then
                              --  Warning if the archive builder failed

                              Set_Tmp_File_Line;
                              Error_Msg
                                ("?extract of object file failed: ~",
                                 Proj.Location);

                              goto Linker_Options_Incomplete;
                           end if;

                           --  Record the extracted object file as temporary
                           Record_Temp_File
                             (Shared => Main_File.Tree.Shared,
                              Path => Obj_Path_Name);

                           --  Extract the linker options section

                           Arg_List := new GNAT.Strings.String_List'
                             (new String'("-s"),
                              new String'("--section=.GPR.linker_options"),
                              Obj);
                           --  Obj going to be Free together with Arg_List

                           Fill_Options_Data_From_Arg_List_Access
                             (Arg_List, Arg_Disp);
                           Display_Command (Arg_Disp, Objdump_Exec);

                           Spawn (Objdump_Exec.all, Arg_List.all, FD, Status);

                           Free (Arg_List);
                           Obj := null;

                           if Status /= 0 then
                              --  Warning if objcopy failed

                              Set_Tmp_File_Line;
                              Error_Msg
                                ("?extract of linker options failed: ~",
                                 Proj.Location);

                              goto Linker_Options_Incomplete;
                           end if;

                           --  Read the objdump output file

                           Open (File, Get_Name_String (Tmp_File));

                           --  Read the linker options

                           while not End_Of_File (File) or else First < 42 loop
                              Decode_Line;

                              if Name_Len > 0
                                and then Name_Buffer (1) = ASCII.NUL
                              then
                                 --  We are reading a NUL character padding at
                                 --  the end of the section: stop here.

                                 exit;
                              end if;

                              --  Add the linker option.
                              --  Avoid duplicates for -L.

                              Lib_Dir_Name := Name_Find;
                              if Name_Len > 2
                                and then Name_Buffer (1 .. 2) = "-L"
                              then
                                 if not Library_Dirs.Get (Lib_Dir_Name) then
                                    Binding_Options.Append
                                      (Name_Buffer (1 .. Name_Len));
                                    Library_Dirs.Set (Lib_Dir_Name, True);
                                 end if;
                              elsif Name_Len > 0 then
                                 Binding_Options.Append
                                   (Name_Buffer (1 .. Name_Len));
                              end if;
                           end loop;

                           Close (File);

                           Success := True;

                           <<Linker_Options_Incomplete>>

                           --  We get here if anything went wrong

                           if not Success and then Opt.Verbose_Mode then
                              Put_Line ("Linker options may be incomplete.");
                           end if;

                           if FD /= Invalid_FD then
                              Close (FD);
                           end if;
                        end;

                     end if;
                  end;

               else
                  --  Do not issue several time the same -L switch if
                  --  several library projects share the same library
                  --  directory.

                  if not Library_Dirs.Get
                           (Library_Projs (J).Proj.Library_Dir.Name)
                  then
                     Library_Dirs.Set
                       (Library_Projs (J).Proj.Library_Dir.Name, True);

                     if Main_Proj.Config.Linker_Lib_Dir_Option = No_Name then
                        Add_To_Other_Arguments
                          ("-L"
                           & Get_Name_String
                               (Library_Projs
                                  (J).Proj.Library_Dir.Display_Name));

                     else
                        Add_To_Other_Arguments
                          (Get_Name_String
                             (Main_Proj.Config.Linker_Lib_Dir_Option)
                           & Get_Name_String
                               (Library_Projs
                                  (J).Proj.Library_Dir.Display_Name));
                     end if;

                     if Opt.Run_Path_Option
                       and then
                         Main_Proj.Config.Run_Path_Option /= No_Name_List
                     then
                        Add_Rpath
                          (Rpaths,
                           Get_Name_String
                             (Library_Projs
                                  (J).Proj.Library_Dir.Display_Name));
                     end if;
                  end if;

                  if Main_Proj.Config.Linker_Lib_Name_Option = No_Name then
                     Add_To_Other_Arguments
                       ("-l" & Get_Name_String
                                 (Library_Projs (J).Proj.Library_Name));

                  else
                     Add_To_Other_Arguments
                       (Get_Name_String
                          (Main_Proj.Config.Linker_Lib_Name_Option)
                        & Get_Name_String
                            (Library_Projs (J).Proj.Library_Name));
                  end if;
               end if;
            end if;
         end loop;

         --  Put the options in the project file, if any

         declare
            The_Packages : constant Package_Id :=
                             Main_Proj.Decl.Packages;

            Linker_Package : constant GPR.Package_Id :=
                               GPR.Util.Value_Of
                                 (Name        => Name_Linker,
                                  In_Packages => The_Packages,
                                  Shared      => Main_File.Tree.Shared);

            Switches    : Variable_Value;
            Switch_List : String_List_Id;
            Element     : String_Element;

         begin
            if Linker_Package /= No_Package then
               declare
                  Defaults       : constant Array_Element_Id :=
                                     GPR.Util.Value_Of
                                       (Name      => Name_Default_Switches,
                                        In_Arrays =>
                                          Main_File.Tree.Shared.Packages.Table
                                            (Linker_Package).Decl.Arrays,
                                        Shared    => Main_File.Tree.Shared);
                  Switches_Array : constant Array_Element_Id :=
                                     GPR.Util.Value_Of
                                       (Name      => Name_Switches,
                                        In_Arrays =>
                                          Main_File.Tree.Shared.Packages.Table
                                            (Linker_Package).Decl.Arrays,
                                        Shared    => Main_File.Tree.Shared);
                  Option         : String_Access;

               begin
                  Switches :=
                    GPR.Util.Value_Of
                      (Index           => Name_Id (Main_Id),
                       Src_Index       => 0,
                       In_Array        => Switches_Array,
                       Shared          => Main_File.Tree.Shared,
                       Allow_Wildcards => True);

                  if Switches = Nil_Variable_Value then
                     Switches :=
                       GPR.Util.Value_Of
                         (Index                  =>
                              Main_Source.Language.Name,
                          Src_Index              => 0,
                          In_Array               => Switches_Array,
                          Shared                 => Main_File.Tree.Shared,
                          Force_Lower_Case_Index => True);
                  end if;

                  if Switches = Nil_Variable_Value then
                     Switches :=
                       GPR.Util.Value_Of
                         (Index                  => All_Other_Names,
                          Src_Index              => 0,
                          In_Array               => Switches_Array,
                          Shared                 => Main_File.Tree.Shared,
                          Force_Lower_Case_Index => True);
                  end if;

                  if Switches = Nil_Variable_Value then
                     Switches :=
                       GPR.Util.Value_Of
                         (Index     =>
                              Main_Source.Language.Name,
                          Src_Index => 0,
                          In_Array  => Defaults,
                          Shared    => Main_File.Tree.Shared);
                  end if;

                  case Switches.Kind is
                     when Undefined | Single =>
                        null;

                     when GPR.List =>
                        Switch_List := Switches.Values;

                        while Switch_List /= Nil_String loop
                           Element :=
                             Main_File.Tree.Shared.String_Elements.Table
                               (Switch_List);
                           Get_Name_String (Element.Value);

                           if Name_Len > 0 then
                              Option :=
                                new String'(Name_Buffer (1 .. Name_Len));

                              Test_If_Relative_Path
                                (Option,
                                 Get_Name_String (Main_Proj.Directory.Name),
                                 Dash_L);

                              Add_Argument
                                (Other_Arguments, Option.all, True);
                              Free (Option);
                           end if;

                           Switch_List := Element.Next;
                        end loop;
                  end case;
               end;
            end if;
         end;

         --  Get the Linker_Options, if any

         Add_Linker_Options (Other_Arguments, For_Project => Main_Proj);

         --  Add the linker switches specified on the command line

         Add_Arguments
           (Other_Arguments,
            Command_Line_Linker_Options,
            Opt.Verbose_Mode);

         --  Then the binding options

         --  If we are linking with static SALs, process the linker options
         --  coming from those SALs the same way as in gprbind (refactoring
         --  needed!!) and add them to the command line.
         --  The parts of the original code related to object files have been
         --  removed since options from static SALs only include flags.

         if Linking_With_Static_SALs then
            declare
               All_Binding_Options : Boolean := False;
               Get_Option          : Boolean;
               Xlinker_Seen        : Boolean := False;
               Stack_Equal_Seen    : Boolean := False;
               Static_Libs         : Boolean := True;

               Adalib_Dir  : String_Access;
               Prefix_Path : String_Access;
               Lib_Path    : String_Access;
            begin
               for Option of Binding_Options loop
                  declare
                     Line : String renames Option;
                     Last : constant Natural := Line'Last;

                     procedure Add_Lib_Path_Or_Line (Lib_Name : String);
                     --  Add full library pathname to the Other_Arguments if
                     --  found in Prefix_Path, add Line to Other_Arguments
                     --  otherwise.

                     --------------------------
                     -- Add_Lib_Path_Or_Line --
                     --------------------------

                     procedure Add_Lib_Path_Or_Line (Lib_Name : String) is
                     begin
                        Lib_Path := Locate_Regular_File
                                      (Lib_Name, Prefix_Path.all);

                        if Lib_Path /= null then
                           Add_To_Other_Arguments (Lib_Path.all);
                           Free (Lib_Path);
                        else
                           Add_To_Other_Arguments (Line);
                        end if;
                     end Add_Lib_Path_Or_Line;

                  begin
                     if Line (1) = '-' then
                        All_Binding_Options := True;
                     end if;

                     Get_Option := All_Binding_Options;

                     if Get_Option then
                        if Line = "-Xlinker" then
                           Xlinker_Seen := True;

                        elsif Xlinker_Seen then
                           Xlinker_Seen := False;

                           if Last > 8 and then Line (1 .. 8) = "--stack=" then
                              if not Stack_Equal_Seen then
                                 Stack_Equal_Seen := True;
                                 Add_To_Other_Arguments ("-Xlinker");
                                 Add_To_Other_Arguments (Line);
                              end if;

                           else
                              Add_To_Other_Arguments ("-Xlinker");
                              Add_To_Other_Arguments (Line);
                           end if;

                        elsif Last > 12
                          and then Line (1 .. 12) = "-Wl,--stack="
                        then
                           if not Stack_Equal_Seen then
                              Stack_Equal_Seen := True;
                              Add_To_Other_Arguments (Line);
                           end if;

                        elsif Last >= 3 and then Line (1 .. 2) = "-L" then
                           if Is_Regular_File
                                (Line (3 .. Last) & Directory_Separator
                                 & "libgnat.a")
                           then
                              Adalib_Dir := new String'(Line (3 .. Last));

                              declare
                                 Dir_Last       : Positive;
                                 Prev_Dir_Last  : Positive;
                                 First          : Positive;
                                 Prev_Dir_First : Positive;
                                 Nmb            : Natural;
                              begin
                                 Set_Name_Buffer (Line (3 .. Last));

                                 while Is_Directory_Separator
                                         (Name_Buffer (Name_Len))
                                 loop
                                    Name_Len := Name_Len - 1;
                                 end loop;

                                 while not Is_Directory_Separator
                                             (Name_Buffer (Name_Len))
                                 loop
                                    Name_Len := Name_Len - 1;
                                 end loop;

                                 while Is_Directory_Separator
                                         (Name_Buffer (Name_Len))
                                 loop
                                    Name_Len := Name_Len - 1;
                                 end loop;

                                 Dir_Last := Name_Len;
                                 Nmb := 0;

                                 Dir_Loop : loop
                                    Prev_Dir_Last := Dir_Last;
                                    First := Dir_Last - 1;
                                    while First > 3
                                      and then not Is_Directory_Separator
                                                     (Name_Buffer (First))
                                    loop
                                       First := First - 1;
                                    end loop;

                                    Prev_Dir_First := First + 1;

                                    exit Dir_Loop when First <= 3;

                                    Dir_Last := First - 1;
                                    while Is_Directory_Separator
                                            (Name_Buffer (Dir_Last))
                                    loop
                                       Dir_Last := Dir_Last - 1;
                                    end loop;

                                    Nmb := Nmb + 1;

                                    if Nmb <= 1 then
                                       Add_Char_To_Name_Buffer
                                         (Path_Separator);
                                       Add_Str_To_Name_Buffer
                                         (Name_Buffer (1 .. Dir_Last));

                                    elsif Name_Buffer
                                      (Prev_Dir_First .. Prev_Dir_Last) = "lib"
                                    then
                                       Add_Char_To_Name_Buffer
                                         (Path_Separator);
                                       Add_Str_To_Name_Buffer
                                         (Name_Buffer (1 .. Prev_Dir_Last));
                                       exit Dir_Loop;
                                    end if;
                                 end loop Dir_Loop;

                                 Prefix_Path :=
                                   new String'(Name_Buffer (1 .. Name_Len));
                              end;
                           end if;
                           Add_To_Other_Arguments (Line);

                        elsif Option in Static_Libgcc | Shared_Libgcc then
                           Add_To_Other_Arguments (Option);
                           Static_Libs := Option = Static_Libgcc;

                        elsif Line = Dash_Lgnat then
                           Add_To_Other_Arguments
                             (if Adalib_Dir = null or else not Static_Libs
                              then Dash_Lgnat
                              else Adalib_Dir.all & "libgnat.a");

                        elsif Line = Dash_Lgnarl
                          and then Static_Libs
                          and then Adalib_Dir /= null
                        then
                           Add_To_Other_Arguments
                             (Adalib_Dir.all & "libgnarl.a");

                        elsif Line = "-laddr2line"
                          and then Prefix_Path /= null
                        then
                           Add_Lib_Path_Or_Line ("libaddr2line.a");

                        elsif Line = "-lbfd"
                          and then Prefix_Path /= null
                        then
                           Add_Lib_Path_Or_Line ("libbfd.a");

                        elsif Line = "-lgnalasup"
                          and then Prefix_Path /= null
                        then
                           Add_Lib_Path_Or_Line ("libgnalasup.a");

                        elsif Line = "-lgnatmon"
                          and then Prefix_Path /= null
                        then
                           Add_Lib_Path_Or_Line ("libgnatmon.a");

                        elsif Line = "-liberty"
                          and then Prefix_Path /= null
                        then
                           Add_Lib_Path_Or_Line ("libiberty.a");

                        else
                           Add_To_Other_Arguments (Line);
                        end if;
                     end if;
                  end;
               end loop;
            end;

         else
            for Option of Binding_Options loop
               Add_To_Other_Arguments (Option);
            end loop;
         end if;

         --  Then the required switches, if any. These are put here because,
         --  if they include -L switches for example, the link may fail because
         --  the wrong objects or libraries are linked in.

         Min_Linker_Opts :=
           Main_Proj.Config.Trailing_Linker_Required_Switches;

         while Min_Linker_Opts /= No_Name_List loop
            Add_To_Other_Arguments
              (Get_Name_String
                 (Main_File.Tree.Shared.Name_Lists.Table
                    (Min_Linker_Opts).Name));
            Min_Linker_Opts   := Main_File.Tree.Shared.Name_Lists.Table
              (Min_Linker_Opts).Next;
         end loop;

         --  Finally the Trailing_Switches if there are any in package Linker.
         --  They are put here so that it is possible to override the required
         --  switches from the configuration project file.

         declare
            The_Packages   : constant Package_Id :=
              Main_Proj.Decl.Packages;
            Linker_Package : constant GPR.Package_Id :=
              GPR.Util.Value_Of
                (Name        => Name_Linker,
                 In_Packages => The_Packages,
                 Shared      => Main_File.Tree.Shared);

            Switches    : Variable_Value;
            Switch_List : String_List_Id;
            Element     : String_Element;

         begin
            if Linker_Package /= No_Package then
               declare
                  Switches_Array : constant Array_Element_Id :=
                    GPR.Util.Value_Of
                      (Name      => Name_Trailing_Switches,
                       In_Arrays =>
                         Main_File.Tree.Shared.Packages.Table
                           (Linker_Package).Decl.Arrays,
                       Shared    => Main_File.Tree.Shared);

               begin
                  Switches :=
                    GPR.Util.Value_Of
                      (Index     => Name_Id (Main_Id),
                       Src_Index => 0,
                       In_Array  => Switches_Array,
                       Shared    => Main_File.Tree.Shared);

                  if Switches = Nil_Variable_Value then
                     Switches :=
                       GPR.Util.Value_Of
                         (Index                  =>
                              Main_Source.Language.Name,
                          Src_Index              => 0,
                          In_Array               => Switches_Array,
                          Shared                 => Main_File.Tree.Shared,
                          Force_Lower_Case_Index => True);
                  end if;

                  if Switches = Nil_Variable_Value then
                     Switches :=
                       GPR.Util.Value_Of
                         (Index                  => All_Other_Names,
                          Src_Index              => 0,
                          In_Array               => Switches_Array,
                          Shared                 => Main_File.Tree.Shared,
                          Force_Lower_Case_Index => True);
                  end if;

                  case Switches.Kind is
                  when Undefined | Single =>
                     null;

                  when GPR.List =>
                     Switch_List := Switches.Values;

                     while Switch_List /= Nil_String loop
                        Element :=
                          Main_File.Tree.Shared.String_Elements.Table
                            (Switch_List);
                        Get_Name_String (Element.Value);

                        Add_Argument
                          (Other_Arguments,
                           Name_Buffer (1 .. Name_Len),
                           True);

                        Switch_List := Element.Next;
                     end loop;
                  end case;
               end;
            end if;
         end;

         --  Remove duplicate stack size setting coming from pragmas
         --  Linker_Options or Link_With and linker switches ("-Xlinker
         --  --stack=R,C" or "-Wl,--stack=R"). Only the first stack size
         --  setting option should be taken into account, because the one in
         --  the project file or on the command line will always be the first
         --  one. And any subsequent stack setting option will overwrite the
         --  previous one.
         --  Also, if Opt.Maximum_Processes is greater than one, check for
         --  switches --lto or -flto and add =nn to the switch.

         Clean_Link_Option_Set : declare
            J        : Natural := Other_Arguments.First_Index;
            Stack_Op : Boolean := False;
            Inc      : Boolean;

         begin
            while J <= Other_Arguments.Last_Index loop
               --  Incriment J by default
               Inc := True;

               --  Check for two switches "-Xlinker" followed by "--stack=..."

               if J /= Other_Arguments.Last_Index
                 and then Other_Arguments (J).Name = "-Xlinker"
                 and then Other_Arguments (J + 1).Name'Length > 8
                 and then Other_Arguments (J + 1).Name (1 .. 8) = "--stack="
               then
                  if Stack_Op then
                     Other_Arguments.Delete (J + 1);
                     Other_Arguments.Delete (J);
                     Inc := False;

                  else
                     Stack_Op := True;
                  end if;

               --  Check for single switch

               elsif (Other_Arguments (J).Name'Length > 17
                   and then Other_Arguments (J).Name (1 .. 17) =
                     "-Xlinker --stack=")
                 or else
                  (Other_Arguments (J).Name'Length > 12
                   and then Other_Arguments (J).Name (1 .. 12) =
                         "-Wl,--stack=")
               then
                  if Stack_Op then
                     Other_Arguments.Delete (J);
                     Inc := False;

                  else
                     Stack_Op := True;
                  end if;

               elsif Opt.Maximum_Linkers > 1 then
                  if Other_Arguments (J).Name in "--lto" | "-flto" then
                     declare
                        Img : String := Opt.Maximum_Linkers'Img;
                        Arg : Option_Type renames Other_Arguments.Element (J);
                     begin
                        Img (1) := '=';
                        Other_Arguments.Replace_Element
                          (J,
                           Option_Type'
                             (Name_Len    => Arg.Name_Len + Img'Length,
                              Name        => Arg.Name & Img,
                              Displayed   => Arg.Displayed,
                              Simple_Name => Arg.Simple_Name));
                     end;
                  end if;
               end if;

               if Inc then
                  J := J + 1;
               end if;
            end loop;
         end Clean_Link_Option_Set;

         --  Look for the last switch -shared-libgcc or -static-libgcc and
         --  remove all the others.

         declare
            Dash_Libgcc : Boolean := False;
         begin
            for Arg in reverse
              Other_Arguments.First_Index .. Other_Arguments.Last_Index
            loop
               if Other_Arguments (Arg).Name in Shared_Libgcc | Static_Libgcc
               then
                  if Dash_Libgcc then
                     Other_Arguments.Delete (Arg);
                  else
                     Dash_Libgcc := True;
                  end if;
               end if;
            end loop;
         end;

         --  Add the run path option, if necessary

         if Opt.Run_Path_Option
           and then Main_Proj.Config.Run_Path_Option /= No_Name_List
         then
            Add_Rpath_From_Arguments (Rpaths, Arguments, Main_Proj);
            Add_Rpath_From_Arguments (Rpaths, Other_Arguments, Main_Proj);
            Add_Run_Path_Options;
         end if;

         --  Add the map file option, if supported and requested

         if Map_File /= null
           and then Main_Proj.Config.Map_File_Option /= No_Name
         then
            Get_Name_String (Main_Proj.Config.Map_File_Option);

            if Map_File'Length > 0 then
               Add_Str_To_Name_Buffer (Map_File.all);

            else
               Get_Name_String_And_Append (Main_Base_Name_Index);
               Add_Str_To_Name_Buffer (".map");
            end if;

            Add_To_Other_Arguments (Name_Buffer (1 .. Name_Len));
         end if;

         --  Add the switch(es) to specify the name of the executable

         declare
            List : Name_List_Index :=
                     Main_Proj.Config.Linker_Executable_Option;
            Nam  : Name_Node;

            procedure Add_Executable_Name;
            --  Add the name of the executable to current name buffer,
            --  then the content of the name buffer as the next argument.

            -------------------------
            -- Add_Executable_Name --
            -------------------------

            procedure Add_Executable_Name is
            begin
               Get_Name_String_And_Append (Exec_Path_Name);
               Add_Argument
                 (Other_Arguments,
                  Name_Buffer (1 .. Name_Len),
                  True,
                  Simple_Name => not Opt.Verbose_Mode);
            end Add_Executable_Name;

         begin
            if List /= No_Name_List then
               loop
                  Nam := Main_File.Tree.Shared.Name_Lists.Table (List);
                  Get_Name_String (Nam.Name);

                  if Nam.Next = No_Name_List then
                     Add_Executable_Name;
                     exit;

                  else
                     Add_Argument
                       (Other_Arguments, Name_Buffer (1 .. Name_Len), True);
                  end if;

                  List := Nam.Next;
               end loop;

            else
               Add_Argument (Other_Arguments, "-o", True);
               Name_Len := 0;
               Add_Executable_Name;
            end if;
         end;

         if Linking_With_Static_SALs then
            --  Filter out duplicate linker options from static SALs:
            --     -T[ ]<linker script> (keep left-most)
            --     --specs=... (keep right-most)

            Remove_Duplicated_T (Arguments);
            Remove_Duplicated_T (Other_Arguments);
            Remove_Duplicated_Specs (Other_Arguments);
            Remove_Duplicated_Specs (Arguments);
         end if;

         --  If response files are supported, check the length of the
         --  command line and the number of object files, then create
         --  a response file if needed.

         if Main_Proj.Config.Max_Command_Line_Length > 0
           and then Main_Proj.Config.Resp_File_Format /= GPR.None
         then
            declare
               Arg_Length            : Natural := 0;
               Min_Number_Of_Objects : Natural := 0;
            begin
               for Arg of Arguments loop
                  Arg_Length := Arg_Length + Arg.Name'Length + 1;
               end loop;
               for Arg of Objects loop
                  Arg_Length := Arg_Length + Arg'Length + 1;
               end loop;
               for Arg of Other_Arguments loop
                  Arg_Length := Arg_Length + Arg.Name'Length + 1;
               end loop;

               if Arg_Length > Main_Proj.Config.Max_Command_Line_Length then
                  if Main_Proj.Config.Resp_File_Options = No_Name_List then
                     Min_Number_Of_Objects := 0;
                  else
                     Min_Number_Of_Objects := 1;
                  end if;

                  --  Don't create a response file if there would not be
                  --  a smaller number of arguments.

                  if Natural (Objects.Length) > Min_Number_Of_Objects then
                     declare
                        Resp_File_Options : String_Vectors.Vector;
                        List              : Name_List_Index :=
                                              Main_Proj.Config.
                                                Resp_File_Options;
                        Nam_Nod           : Name_Node;
                        Other_Args        : String_Vectors.Vector;

                     begin
                        while List /= No_Name_List loop
                           Nam_Nod :=
                             Main_File.Tree.Shared.Name_Lists.Table (List);
                           Resp_File_Options.Append
                             (Get_Name_String (Nam_Nod.Name));
                           List := Nam_Nod.Next;
                        end loop;

                        for Arg of Other_Arguments loop
                           Other_Args.Append (Arg.Name);
                        end loop;

                        Aux.Create_Response_File
                          (Format            =>
                             Main_Proj.Config.Resp_File_Format,
                           Objects           => Objects,
                           Other_Arguments   => Other_Args,
                           Resp_File_Options => Resp_File_Options,
                           Name_1            => Response_File_Name,
                           Name_2            => Response_2);

                        Record_Temp_File
                          (Shared => Main_File.Tree.Shared,
                           Path   => Response_File_Name);

                        if Response_2 /= No_Path then
                           Record_Temp_File
                             (Shared => Main_File.Tree.Shared,
                              Path   => Response_2);
                        end if;

                        if Main_Proj.Config.Resp_File_Format in GCC | GCC_GNU |
                              GCC_Object_List | GCC_Option_List
                        then
                           Add_Argument
                             (Arguments,
                              "@" & Get_Name_String (Response_File_Name),
                              Opt.Verbose_Mode);
                           Objects.Clear;
                           Other_Arguments.Clear;

                        else
                           --  Replace the first object file arguments
                           --  with the argument(s) specifying the
                           --  response file. No need to update
                           --  Arguments_Displayed, as the values are
                           --  already correct (= Verbose_Mode).

                           if Resp_File_Options.Is_Empty then
                              Add_Argument
                                (Arguments,
                                 Get_Name_String (Response_File_Name),
                                 Opt.Verbose_Mode);
                              Objects.Clear;

                           else
                              Resp_File_Options.Replace_Element
                                (Resp_File_Options.Last_Index,
                                 Resp_File_Options.Last_Element &
                                 Get_Name_String (Response_File_Name));
                              Add_Arguments
                                (Arguments, Resp_File_Options,
                                 Opt.Verbose_Mode);
                              Objects.Clear;
                           end if;

                           --  And put the arguments following the object
                           --  files immediately after the response file
                           --  argument(s). Update Arguments_Displayed
                           --  too.

                           Arguments.Append_Vector (Other_Arguments);
                           Other_Arguments.Clear;
                        end if;
                     end;
                  end if;
               end if;
            end;
         end if;

         --  Complete the command line if needed

         for Obj of Objects loop
            Add_Argument
              (Arguments,
               Obj,
               Opt.Verbose_Mode,
               not Opt.Verbose_Mode);
         end loop;

         Arguments.Append_Vector (Other_Arguments);

         Objects.Clear;
         Other_Arguments.Clear;

         --  Delete an eventual executable, in case it is a symbolic
         --  link as we don't want to modify the target of the link.

         declare
            Dummy : Boolean;

         begin
            Delete_File (Get_Name_String (Exec_Path_Name), Dummy);
         end;

         if not Opt.Quiet_Output then
            if Opt.Verbose_Mode then
               Display_Command (Arguments, Linker_Path);
            else
               Display
                 (Section  => GPR.Link,
                  Command  => "link",
                  Argument => Main);
            end if;
         end if;

         declare
            Pid         : Process_Id;
            Args_Vector : String_Vectors.Vector;
            Args_List   : String_List_Access;
         begin
            Main_File.Command.Append (Linker_Path.all);

            for Arg of Arguments loop
               Args_Vector.Append (Arg.Name);
               Main_File.Command.Append (Arg.Name);
            end loop;

            Args_List := new String_List'(To_Argument_List (Args_Vector));

            Script_Write
              (Linker_Path.all,  Args_Vector);
            Pid := Non_Blocking_Spawn
              (Linker_Path.all,  Args_List.all);

            Free (Args_List);

            if Pid = Invalid_Pid then
               Put ("Can't start linker ");
               Put_Line (Linker_Path.all);
               Record_Failure (Main_File);

            else
               Add_Process (Pid, (Linking, Main_File));
               Display_Processes ("link");
            end if;
         end;
      end if;

   end Link_Main;

   ---------
   -- Run --
   ---------

   procedure Run is

      Main : Main_Info;

      procedure Do_Link (Project : Project_Id; Tree : Project_Tree_Ref);

      procedure Await_Link;

      procedure Wait_For_Available_Slot;

      ----------------
      -- Await_Link --
      ----------------

      procedure Await_Link is
         Data : Process_Data;
         OK   : Boolean;
      begin
         loop
            Await_Process (Data, OK);

            if Data /= No_Process_Data then

               if not OK then
                  Exit_Code := E_Subtool;
                  Record_Failure (Data.Main);
               end if;

               Display_Processes ("link");
               return;
            end if;
         end loop;
      end Await_Link;

      -------------
      -- Do_Link --
      -------------

      procedure Do_Link (Project : Project_Id; Tree : Project_Tree_Ref) is
         pragma Unreferenced (Project);
         Main_File : Main_Info;
      begin
         if Builder_Data (Tree).Need_Linking and then not Stop_Spawning then
            Mains.Reset;
            loop
               Main_File := Mains.Next_Main;
               exit when Main_File = No_Main_Info;

               if Main_File.Tree = Tree
                 and then not Project_Compilation_Failed (Main_File.Project)
                 and then Main_File.Source.Language.Config.Compiler_Driver
                          /= Empty_File
               then
                  Wait_For_Available_Slot;
                  exit when Stop_Spawning;
                  Link_Main (Main_File);
                  exit when Stop_Spawning;
               end if;
            end loop;
         end if;
      end Do_Link;

      procedure Link_All is new For_Project_And_Aggregated (Do_Link);

      -----------------------------
      -- Wait_For_Available_Slot --
      -----------------------------

      procedure Wait_For_Available_Slot is
      begin
         while Outstanding_Processes >= Opt.Maximum_Linkers loop
            Await_Link;
         end loop;
      end Wait_For_Available_Slot;

   begin
      Outstanding_Processes := 0;
      Stop_Spawning := False;
      Link_All (Main_Project, Project_Tree);

      while Outstanding_Processes > 0 loop
         Await_Link;
      end loop;

      if Bad_Processes.Length = 1 then
         Main := Bad_Processes.First_Element;
         Fail_Program
           (Main.Tree,
            "link of " & Get_Name_String (Main.File) & " failed",
            Command =>
              (if Main.Command.Is_Empty
                 or else Opt.Verbosity_Level /= Opt.None then ""
               else "failed command was: " & String_Vector_To_String
                                               (Main.Command)),
            Exit_Code => E_Subtool);

      elsif not Bad_Processes.Is_Empty then
         for Main of Bad_Processes loop
            Put ("   link of ");
            Put (Get_Name_String (Main.File));
            Put_Line (" failed");
            if not Main.Command.Is_Empty and then
              Opt.Verbosity_Level = Opt.None
            then
               Put_Line ("   failed command was: "
                         & String_Vector_To_String (Main.Command));
            end if;
         end loop;

         Fail_Program
           (Bad_Processes.Last_Element.Tree, "*** link phase failed",
            Exit_Code => E_Subtool);
      end if;
   end Run;

end Gprbuild.Link;
