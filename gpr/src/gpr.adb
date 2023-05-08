------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2022, Free Software Foundation, Inc.         --
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

with Ada.Characters.Handling;     use Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;   use Ada.Environment_Variables;
with Ada.Text_IO;                 use Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;

with GPR.Opt;
with GPR.Attr;
with GPR.Names;  use GPR.Names;
with GPR.Output; use GPR.Output;
with GPR.Snames; use GPR.Snames;

package body GPR is

   type Restricted_Lang;
   type Restricted_Lang_Access is access Restricted_Lang;
   type Restricted_Lang is record
      Name : Name_Id;
      Next : Restricted_Lang_Access;
   end record;

   Initialized : Boolean := False;
   --  A flag to avoid multiple initialization

   Restricted_Languages : Restricted_Lang_Access := null;
   --  When null, all languages are allowed, otherwise only the languages in
   --  the list are allowed.

   Object_Suffix : constant String := Get_Target_Object_Suffix.all;
   --  File suffix for object files

   Initial_Buffer_Size : constant := 100;
   --  Initial size for extensible buffer used in Add_To_Buffer

   Debug_Level : Integer := 0;
   --  Current indentation level for debug traces

   type Cst_String_Access is access constant String;

   All_Lower_Case_Image : aliased constant String := "lowercase";
   All_Upper_Case_Image : aliased constant String := "UPPERCASE";
   Mixed_Case_Image     : aliased constant String := "MixedCase";

   The_Casing_Images : constant array (Casing_Type) of Cst_String_Access :=
                         (All_Lower_Case => All_Lower_Case_Image'Access,
                          All_Upper_Case => All_Upper_Case_Image'Access,
                          Mixed_Case     => Mixed_Case_Image'Access,
                          Unknown        => null);

   type Section_Displayed_Arr is array (Section_Type) of Boolean;
   Section_Displayed : Section_Displayed_Arr := (others => False);
   --  Flags to avoid to display several times the section header

   Temp_Files : Temp_Files_Table.Instance;
   --  Table to record temp file paths to be deleted, when no project tree is
   --  available.

   function Label (Section : Section_Type) return String;
   --  Section headers

   procedure Free (Project : in out Project_Id);
   --  Free memory allocated for Project

   procedure Free_List (Languages : in out Language_Ptr);
   procedure Free_List (Source : in out Source_Id);
   procedure Free_List (Languages : in out Language_List);
   --  Free memory allocated for the list of languages or sources

   procedure Reset_Units_In_Table (Table : in out Units_Htable.Instance);
   --  Resets all Units to No_Unit_Index Unit.File_Names (Spec).Unit &
   --  Unit.File_Names (Impl).Unit in the given table.

   procedure Free_Units (Table : in out Units_Htable.Instance);
   --  Free memory allocated for unit information in the project

   procedure Language_Changed (Iter : in out Source_Iterator);
   procedure Project_Changed (Iter : in out Source_Iterator);
   --  Called when a new project or language was selected for this iterator

   function Contains_ALI_Files (Dir : Path_Name_Type) return Boolean;
   --  Return True if there is at least one ALI file in the directory Dir

   -----------------------------
   -- Add_Restricted_Language --
   -----------------------------

   procedure Add_Restricted_Language (Name : String) is
   begin
      Restricted_Languages :=
        new Restricted_Lang'
          (Name => Get_Lower_Name_Id (Name), Next => Restricted_Languages);
   end Add_Restricted_Language;

   -----------------
   -- Add_To_Path --
   -----------------

   procedure Add_To_Path
     (Directory : String;
      Append    : Boolean := False;
      Variable  : String := "PATH")
   is

      procedure Update (Path : String);
      --  Update value of Variable. Path is its current value;

      ------------
      -- Update --
      ------------

      procedure Update (Path : String) is
      begin
         if Path'Length = 0 then
            Set (Variable, Directory);

         elsif Append then
            Set (Variable, Path & Path_Separator & Directory);

         else
            Set (Variable, Directory & Path_Separator & Path);
         end if;
      end Update;

   begin
      if Directory'Length /= 0 then
         if not Exists (Variable) then
            Update ("");

         else
            Update (Value (Variable));
         end if;
      end if;
   end Add_To_Path;

   -------------------------------------
   -- Remove_All_Restricted_Languages --
   -------------------------------------

   procedure Remove_All_Restricted_Languages is
   begin
      Restricted_Languages := null;
   end Remove_All_Restricted_Languages;

   -------------------
   -- Add_To_Buffer --
   -------------------

   procedure Add_To_Buffer
     (S    : String;
      To   : in out String_Access;
      Last : in out Natural)
   is
   begin
      if To = null then
         To := new String (1 .. Initial_Buffer_Size);
         Last := 0;
      end if;

      --  If Buffer is too small, double its size

      while Last + S'Length > To'Last loop
         declare
            New_Buffer : constant  String_Access :=
                           new String (1 .. 2 * To'Length);
         begin
            New_Buffer (1 .. Last) := To (1 .. Last);
            Free (To);
            To := New_Buffer;
         end;
      end loop;

      To (Last + 1 .. Last + S'Length) := S;
      Last := Last + S'Length;
   end Add_To_Buffer;

   ---------------------------------
   -- Current_Object_Path_File_Of --
   ---------------------------------

   function Current_Object_Path_File_Of
     (Shared : Shared_Project_Tree_Data_Access) return Path_Name_Type
   is
   begin
      return Shared.Private_Part.Current_Object_Path_File;
   end Current_Object_Path_File_Of;

   ---------------------------------
   -- Current_Source_Path_File_Of --
   ---------------------------------

   function Current_Source_Path_File_Of
     (Shared : Shared_Project_Tree_Data_Access)
      return Path_Name_Type is
   begin
      return Shared.Private_Part.Current_Source_Path_File;
   end Current_Source_Path_File_Of;

   ---------------------------
   -- Delete_Temporary_File --
   ---------------------------

   procedure Delete_Temporary_File
     (Shared : Shared_Project_Tree_Data_Access := null;
      Path   : Path_Name_Type)
   is
      Dont_Care : Boolean;
      pragma Warnings (Off, Dont_Care);

   begin
      if not Opt.Keep_Temporary_Files then
         if Current_Verbosity = High then
            Write_Line ("Removing temp file: " & Get_Name_String (Path));
         end if;

         Delete_File (Get_Name_String (Path), Dont_Care);

         if Shared = null then
            for Index in
              1 .. Temp_Files_Table.Last (Temp_Files)
            loop
               if Temp_Files.Table (Index) = Path then
                  Temp_Files.Table (Index) := No_Path;
               end if;
            end loop;

         else
            for Index in
              1 .. Temp_Files_Table.Last (Shared.Private_Part.Temp_Files)
            loop
               if Shared.Private_Part.Temp_Files.Table (Index) = Path then
                  Shared.Private_Part.Temp_Files.Table (Index) := No_Path;
               end if;
            end loop;
         end if;
      end if;
   end Delete_Temporary_File;

   procedure Delete_Temporary_File
     (Shared : Shared_Project_Tree_Data_Access := null;
      Path   : String) is
   begin
      Delete_Temporary_File (Shared, Get_Path_Name_Id (Path));
   end Delete_Temporary_File;

   ---------------------------
   -- Delete_All_Temp_Files --
   ---------------------------

   procedure Delete_All_Temp_Files
     (Shared : Shared_Project_Tree_Data_Access)
   is
      Success : Boolean;
      Path    : Path_Name_Type;

      Instance : Temp_Files_Table.Instance;

   begin
      if not Opt.Keep_Temporary_Files then
         if Shared = null then
            Instance := Temp_Files;
         else
            Instance := Shared.Private_Part.Temp_Files;
         end if;

         for Index in
           1 .. Temp_Files_Table.Last (Instance)
         loop
            Path := Instance.Table (Index);

            if Path /= No_Path then
               declare
                  Path_Name : constant String := Get_Name_String (Path);
               begin
                  if Current_Verbosity = High then
                     Write_Line ("Removing temp file: " & Path_Name);
                  end if;

                  Delete_File (Path_Name, Success);

                  if not Success then
                     if Is_Regular_File (Path_Name) then
                        Write_Line
                          ("Could not remove temp file " & Path_Name);

                     elsif Current_Verbosity = High then
                        Write_Line
                          ("Temp file " & Path_Name & " already deleted");
                     end if;
                  end if;
               end;
            end if;
         end loop;

         if Shared = null then
            Temp_Files_Table.Init (Temp_Files);
         else
            Temp_Files_Table.Init (Shared.Private_Part.Temp_Files);
         end if;
      end if;

      if Shared /= null then
         --  If any of the environment variables ADA_PRJ_INCLUDE_FILE or
         --  ADA_PRJ_OBJECTS_FILE has been set, then reset their value to
         --  the empty string.

         if Shared.Private_Part.Current_Source_Path_File /= No_Path then
            Setenv (Project_Include_Path_File, "");
         end if;

         if Shared.Private_Part.Current_Object_Path_File /= No_Path then
            Setenv (Project_Objects_Path_File, "");
         end if;
      end if;
   end Delete_All_Temp_Files;

   ---------------------
   -- Dependency_Name --
   ---------------------

   function Dependency_Name
     (Source_File_Name : File_Name_Type;
      Dependency       : Dependency_File_Kind) return File_Name_Type
   is
   begin
      case Dependency is
         when None =>
            return No_File;

         when Makefile =>
            return Extend_Name (Source_File_Name, Makefile_Dependency_Suffix);

         when ALI_Dependency =>
            return Extend_Name (Source_File_Name, ALI_Dependency_Suffix);
      end case;
   end Dependency_Name;

   ---------
   -- Set --
   ---------

   procedure Set (Section : Section_Type)
   is
   begin
      Section_Displayed (Section) := True;
   end Set;

   -------------
   -- Display --
   -------------

   procedure Display
     (Section  : Section_Type;
      Command  : String;
      Argument : String)
   is
      Buffer : String (1 .. 1_000);
      Last   : Natural := 0;

      First_Offset  : constant := 3;
      Second_Offset : constant := 18;

   begin
      --  Display the section header if not already displayed

      if not Section_Displayed (Section) then
         Put_Line (Label (Section));
         Section_Displayed (Section) := True;
      end if;

      Buffer (1 .. First_Offset) := (others => ' ');
      Last := First_Offset + 1;
      Buffer (Last) := '[';
      Buffer (Last + 1 .. Last + Command'Length) := Command;
      Last := Last + Command'Length + 1;
      Buffer (Last) := ']';

      --  At least one space between first and second column. Second column
      --  starts at least at Second_Offset + 1.

      loop
         Last := Last + 1;
         Buffer (Last) := ' ';
         exit when Last >= Second_Offset;
      end loop;

      Buffer (Last + 1 .. Last + Argument'Length) := Argument;
      Last := Last + Argument'Length;

      Put_Line (Buffer (1 .. Last));
   end Display;

   ----------------
   -- Dot_String --
   ----------------

   function Dot_String return Name_Id is
   begin
      return The_Dot_String;
   end Dot_String;

   ----------------
   -- Empty_File --
   ----------------

   function Empty_File return File_Name_Type is
   begin
      return File_Name_Type (The_Empty_String);
   end Empty_File;

   -------------------
   -- Empty_Project --
   -------------------

   function Empty_Project
     (Qualifier : Project_Qualifier) return Project_Data
   is
   begin
      GPR.Initialize (Tree => No_Project_Tree);

      declare
         Data : Project_Data (Qualifier => Qualifier);

      begin
         --  Only the fields for which no default value could be provided in
         --  prj.ads are initialized below.

         Data.Config := Default_Project_Config;
         return Data;
      end;
   end Empty_Project;

   ------------------
   -- Empty_String --
   ------------------

   function Empty_String return Name_Id is
   begin
      return The_Empty_String;
   end Empty_String;

   -----------------
   -- Extend_Name --
   -----------------

   function Extend_Name
     (File        : File_Name_Type;
      With_Suffix : String) return File_Name_Type
   is
      Last : Positive;

   begin
      Get_Name_String (File);
      Last := Name_Len + 1;

      while Name_Len /= 0 and then Name_Buffer (Name_Len) /= '.' loop
         Name_Len := Name_Len - 1;
      end loop;

      if Name_Len <= 1 then
         Name_Len := Last;
      end if;

      for J in With_Suffix'Range loop
         Name_Buffer (Name_Len) := With_Suffix (J);
         Name_Len := Name_Len + 1;
      end loop;

      Name_Len := Name_Len - 1;
      return Name_Find;
   end Extend_Name;

   ----------
   -- Free --
   ----------

   procedure Free (Proj : in out Project_Node_Tree_Ref) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Project_Node_Tree_Data, Project_Node_Tree_Ref);
   begin
      if Proj /= null then
         Tree_Private_Part.Project_Node_Table.Free (Proj.Project_Nodes);
         Tree_Private_Part.Projects_Htable.Reset (Proj.Projects_HT);
         Unchecked_Free (Proj);
      end if;
   end Free;

   -------------------------
   -- Is_Allowed_Language --
   -------------------------

   function Is_Allowed_Language (Name : Name_Id) return Boolean is
      R    : Restricted_Lang_Access := Restricted_Languages;
      Lang : constant String := Get_Name_String (Name);

   begin
      if R = null then
         return True;

      else
         while R /= null loop
            if Get_Name_String (R.Name) = Lang then
               return True;
            end if;

            R := R.Next;
         end loop;

         return False;
      end if;
   end Is_Allowed_Language;

   ---------------------
   -- Project_Changed --
   ---------------------

   procedure Project_Changed (Iter : in out Source_Iterator) is
   begin
      if Iter.Project /= null then
         Iter.Language := Iter.Project.Project.Languages;
         Language_Changed (Iter);
      end if;
   end Project_Changed;

   ----------------------
   -- Language_Changed --
   ----------------------

   procedure Language_Changed (Iter : in out Source_Iterator) is
   begin
      Iter.Current := No_Source;

      if Iter.Language_Name /= No_Name then
         while Iter.Language /= null
           and then Iter.Language.Name /= Iter.Language_Name
         loop
            Iter.Language := Iter.Language.Next;
         end loop;
      end if;

      --  If there is no matching language in this project, move to next

      if Iter.Language = No_Language_Index then
         if Iter.All_Projects then
            loop
               Iter.Project := Iter.Project.Next;
               exit when Iter.Project = null
                 or else Iter.Encapsulated_Libs
                 or else not Iter.Project.From_Encapsulated_Lib;
            end loop;

            Project_Changed (Iter);
         else
            Iter.Project := null;
         end if;

      else
         Iter.Current := Iter.Language.First_Source;

         if Iter.Current = No_Source then
            Iter.Language := Iter.Language.Next;
            Language_Changed (Iter);

         elsif not Iter.Locally_Removed
           and then Iter.Current.Locally_Removed
         then
            Next (Iter);
         end if;
      end if;
   end Language_Changed;

   ---------------------
   -- For_Each_Source --
   ---------------------

   function For_Each_Source
     (In_Tree           : Project_Tree_Ref;
      Project           : Project_Id := No_Project;
      Language          : Name_Id := No_Name;
      Encapsulated_Libs : Boolean := True;
      Locally_Removed   : Boolean := True) return Source_Iterator
   is
      Iter : Source_Iterator;
   begin
      Iter := Source_Iterator'
        (In_Tree           => In_Tree,
         Project           => In_Tree.Projects,
         All_Projects      => Project = No_Project,
         Language_Name     => Language,
         Language          => No_Language_Index,
         Current           => No_Source,
         Encapsulated_Libs => Encapsulated_Libs,
         Locally_Removed   => Locally_Removed);

      if Project /= null then
         while Iter.Project /= null
           and then Iter.Project.Project /= Project
         loop
            Iter.Project := Iter.Project.Next;
         end loop;

      elsif not Encapsulated_Libs then
         while Iter.Project /= null
           and then Iter.Project.From_Encapsulated_Lib
         loop
            Iter.Project := Iter.Project.Next;
         end loop;
      end if;

      Project_Changed (Iter);

      return Iter;
   end For_Each_Source;

   -------------
   -- Element --
   -------------

   function Element (Iter : Source_Iterator) return Source_Id is
   begin
      return Iter.Current;
   end Element;

   ----------
   -- Next --
   ----------

   procedure Next (Iter : in out Source_Iterator) is
   begin
      loop
         Iter.Current := Iter.Current.Next_In_Lang;

         exit when Iter.Locally_Removed
           or else Iter.Current = No_Source
           or else not Iter.Current.Locally_Removed;
      end loop;

      if Iter.Current = No_Source then
         Iter.Language := Iter.Language.Next;
         Language_Changed (Iter);
      end if;
   end Next;

   ----------------------------------------
   -- For_Every_Project_Imported_Context --
   ----------------------------------------

   procedure For_Every_Project_Imported_Context
     (By                 : Project_Id;
      Tree               : Project_Tree_Ref;
      With_State         : in out State;
      Include_Aggregated : Boolean := True;
      Imported_First     : Boolean := False)
   is
      procedure Recursive_Check_Context
        (Project               : Project_Id;
         Tree                  : Project_Tree_Ref;
         In_Aggregate_Lib      : Boolean;
         From_Encapsulated_Lib : Boolean);
      --  Recursively handle the project tree creating a new context for
      --  keeping track about already handled projects.

      -----------------------------
      -- Recursive_Check_Context --
      -----------------------------

      procedure Recursive_Check_Context
        (Project               : Project_Id;
         Tree                  : Project_Tree_Ref;
         In_Aggregate_Lib      : Boolean;
         From_Encapsulated_Lib : Boolean)
      is
         Position  : Name_Id_Set.Cursor;
         Inserted  : Boolean;
         Seen_Name : Name_Id_Set.Set;
         --  This set is needed to ensure that we do not handle the same
         --  project twice in the context of aggregate libraries.

         procedure Recursive_Check
           (Project               : Project_Id;
            Tree                  : Project_Tree_Ref;
            In_Aggregate_Lib      : Boolean;
            From_Encapsulated_Lib : Boolean);
         --  Check if project has already been seen. If not, mark it as Seen,
         --  Call Action, and check all its imported and aggregated projects.

         ---------------------
         -- Recursive_Check --
         ---------------------

         procedure Recursive_Check
           (Project               : Project_Id;
            Tree                  : Project_Tree_Ref;
            In_Aggregate_Lib      : Boolean;
            From_Encapsulated_Lib : Boolean)
         is

            function Has_Sources (P : Project_Id) return Boolean;
            --  Returns True if P has sources

            function Get_From_Tree (P : Project_Id) return Project_Id;
            --  Get project P from Tree. If P has no sources get another
            --  instance of this project with sources. If P has sources,
            --  returns it.

            -----------------
            -- Has_Sources --
            -----------------

            function Has_Sources (P : Project_Id) return Boolean is
               Lang : Language_Ptr;

            begin
               Lang := P.Languages;
               while Lang /= No_Language_Index loop
                  if Lang.First_Source /= No_Source then
                     return True;
                  end if;

                  Lang := Lang.Next;
               end loop;

               return False;
            end Has_Sources;

            -------------------
            -- Get_From_Tree --
            -------------------

            function Get_From_Tree (P : Project_Id) return Project_Id is
               List : Project_List := Tree.Projects;

            begin
               if not Has_Sources (P) then
                  while List /= null loop
                     if List.Project.Name = P.Name
                       and then Has_Sources (List.Project)
                     then
                        return List.Project;
                     end if;

                     List := List.Next;
                  end loop;
               end if;

               return P;
            end Get_From_Tree;

            --  Local variables

            List : Project_List;

         --  Start of processing for Recursive_Check

         begin
            --  If a non abstract imported project is extended, then the actual
            --  imported is the extending project.

            if Project.Qualifier /= Abstract_Project and then
              Project.Extended_By /= No_Project and then
              not Seen_Name.Contains (Project.Extended_By.Name)
            then
               Recursive_Check
                 (Project.Extended_By, Tree,
                  In_Aggregate_Lib, From_Encapsulated_Lib);
            end if;

            Seen_Name.Insert (Project.Name, Position, Inserted);

            if Inserted then

               --  Even if a project is aggregated multiple times in an
               --  aggregated library, we will only return it once.

               if not Imported_First then
                  if Project.Qualifier /= Abstract_Project or else
                    Project.Extended_By = No_Project
                  then
                     Action
                       (Get_From_Tree (Project),
                        Tree,
                        Project_Context'
                          (In_Aggregate_Lib,
                           From_Encapsulated_Lib),
                        With_State);
                  end if;
               end if;

               --  Visit all extended projects

               if Project.Extends /= No_Project then
                  Recursive_Check
                    (Project.Extends, Tree,
                     In_Aggregate_Lib, From_Encapsulated_Lib);
               end if;

               --  Visit all imported projects

               List := Project.Imported_Projects;
               while List /= null loop
                  Recursive_Check
                    (List.Project, Tree,
                     In_Aggregate_Lib,
                     From_Encapsulated_Lib
                       or else Project.Standalone_Library = Encapsulated);
                  List := List.Next;
               end loop;

               --  Visit all aggregated projects

               if Include_Aggregated
                 and then Project.Qualifier in Aggregate_Project
               then
                  declare
                     Agg : Aggregated_Project_List;

                  begin
                     Agg := Project.Aggregated_Projects;
                     while Agg /= null loop
                        pragma Assert (Agg.Project /= No_Project);

                        --  For aggregated libraries, the tree must be the one
                        --  of the aggregate library.

                        if Project.Qualifier = Aggregate_Library then
                           Recursive_Check
                             (Agg.Project, Tree,
                              True,
                              From_Encapsulated_Lib
                                or else
                                  Project.Standalone_Library = Encapsulated);

                        else
                           --  Use a new context as we want to returns the same
                           --  project in different project tree for aggregated
                           --  projects.

                           Recursive_Check_Context
                             (Agg.Project, Agg.Tree, False, False);
                        end if;

                        Agg := Agg.Next;
                     end loop;
                  end;
               end if;

               if Imported_First then
                  if Project.Qualifier /= Abstract_Project or else
                    Project.Extended_By = No_Project
                  then
                     Action
                       (Get_From_Tree (Project),
                        Tree,
                        Project_Context'
                          (In_Aggregate_Lib,
                           From_Encapsulated_Lib),
                        With_State);
                  end if;
               end if;
            end if;
         end Recursive_Check;

      --  Start of processing for Recursive_Check_Context

      begin
         Recursive_Check
           (Project, Tree, In_Aggregate_Lib, From_Encapsulated_Lib);
      end Recursive_Check_Context;

   --  Start of processing for For_Every_Project_Imported

   begin
      Recursive_Check_Context
        (Project               => By,
         Tree                  => Tree,
         In_Aggregate_Lib      => False,
         From_Encapsulated_Lib => False);
   end For_Every_Project_Imported_Context;

   --------------------------------
   -- For_Every_Project_Imported --
   --------------------------------

   procedure For_Every_Project_Imported
     (By                 : Project_Id;
      Tree               : Project_Tree_Ref;
      With_State         : in out State;
      Include_Aggregated : Boolean := True;
      Imported_First     : Boolean := False)
   is
      procedure Internal
        (Project    : Project_Id;
         Tree       : Project_Tree_Ref;
         Context    : Project_Context;
         With_State : in out State);
      --  Action wrapper for handling the context

      --------------
      -- Internal --
      --------------

      procedure Internal
        (Project    : Project_Id;
         Tree       : Project_Tree_Ref;
         Context    : Project_Context;
         With_State : in out State)
      is
         pragma Unreferenced (Context);
      begin
         Action (Project, Tree, With_State);
      end Internal;

      procedure For_Projects is
        new For_Every_Project_Imported_Context (State, Internal);

   begin
      For_Projects (By, Tree, With_State, Include_Aggregated, Imported_First);
   end For_Every_Project_Imported;

   -----------------
   -- Find_Source --
   -----------------

   function Find_Source
     (In_Tree          : Project_Tree_Ref;
      Project          : Project_Id;
      In_Imported_Only : Boolean := False;
      In_Extended_Only : Boolean := False;
      Base_Name        : File_Name_Type;
      Index            : Int := 0) return Source_Id
   is
      Result : Source_Id  := No_Source;

      procedure Look_For_Sources
        (Proj : Project_Id;
         Tree : Project_Tree_Ref;
         Src  : in out Source_Id);
      --  Look for Base_Name in the sources of Proj

      ----------------------
      -- Look_For_Sources --
      ----------------------

      procedure Look_For_Sources
        (Proj : Project_Id;
         Tree : Project_Tree_Ref;
         Src  : in out Source_Id)
      is
         Iterator : Source_Iterator;

      begin
         Iterator := For_Each_Source (In_Tree => Tree, Project => Proj);
         while Element (Iterator) /= No_Source loop
            if Element (Iterator).File = Base_Name
              and then (Index = 0 or else Element (Iterator).Index = Index)
            then
               Src := Element (Iterator);

               --  If the source has been excluded, continue looking. We will
               --  get the excluded source only if there is no other source
               --  with the same base name that is not locally removed.

               if not Element (Iterator).Locally_Removed then
                  return;
               end if;
            end if;

            Next (Iterator);
         end loop;
      end Look_For_Sources;

      procedure For_Imported_Projects is new For_Every_Project_Imported
        (State => Source_Id, Action => Look_For_Sources);

      Proj : Project_Id;

   --  Start of processing for Find_Source

   begin
      if In_Extended_Only then
         Proj := Project;
         while Proj /= No_Project loop
            Look_For_Sources (Proj, In_Tree, Result);
            exit when Result /= No_Source;

            Proj := Proj.Extends;
         end loop;

      elsif In_Imported_Only then
         Look_For_Sources (Project, In_Tree, Result);

         if Result = No_Source then
            For_Imported_Projects
              (By                 => Project,
               Tree               => In_Tree,
               Include_Aggregated => False,
               With_State         => Result);
         end if;

      else
         Look_For_Sources (No_Project, In_Tree, Result);
      end if;

      return Result;
   end Find_Source;

   ----------------------
   -- Find_All_Sources --
   ----------------------

   function Find_All_Sources
     (In_Tree          : Project_Tree_Ref;
      Project          : Project_Id;
      In_Imported_Only : Boolean := False;
      In_Extended_Only : Boolean := False;
      Base_Name        : File_Name_Type;
      Index            : Int := 0) return Source_Ids
   is
      Result : Source_Ids (1 .. 1_000);
      Last   : Natural := 0;

      type Empty_State is null record;
      No_State : Empty_State;
      --  This is needed for the State parameter of procedure Look_For_Sources
      --  below, because of the instantiation For_Imported_Projects of generic
      --  procedure For_Every_Project_Imported. As procedure Look_For_Sources
      --  does not modify parameter State, there is no need to give its type
      --  more than one value.

      procedure Look_For_Sources
        (Proj  : Project_Id;
         Tree  : Project_Tree_Ref;
         State : in out Empty_State);
      --  Look for Base_Name in the sources of Proj

      ----------------------
      -- Look_For_Sources --
      ----------------------

      procedure Look_For_Sources
        (Proj  : Project_Id;
         Tree  : Project_Tree_Ref;
         State : in out Empty_State)
      is
         Iterator : Source_Iterator;
         Src : Source_Id;

      begin
         State := No_State;

         Iterator := For_Each_Source (In_Tree => Tree, Project => Proj);
         while Element (Iterator) /= No_Source loop
            if Element (Iterator).File = Base_Name
              and then (Index = 0
                        or else
                          (Element (Iterator).Unit /= No_Unit_Index
                           and then
                           Element (Iterator).Index = Index))
            then
               Src := Element (Iterator);

               --  If the source has been excluded, continue looking. We will
               --  get the excluded source only if there is no other source
               --  with the same base name that is not locally removed.

               if not Element (Iterator).Locally_Removed then
                  Last := Last + 1;
                  Result (Last) := Src;
               end if;
            end if;

            Next (Iterator);
         end loop;
      end Look_For_Sources;

      procedure For_Imported_Projects is new For_Every_Project_Imported
        (State => Empty_State, Action => Look_For_Sources);

      Proj : Project_Id;

   --  Start of processing for Find_All_Sources

   begin
      if In_Extended_Only then
         Proj := Project;
         while Proj /= No_Project loop
            Look_For_Sources (Proj, In_Tree, No_State);
            exit when Last > 0;
            Proj := Proj.Extends;
         end loop;

      elsif In_Imported_Only then
         Look_For_Sources (Project, In_Tree, No_State);

         if Last = 0 then
            For_Imported_Projects
              (By                 => Project,
               Tree               => In_Tree,
               Include_Aggregated => False,
               With_State         => No_State);
         end if;

      else
         Look_For_Sources (No_Project, In_Tree, No_State);
      end if;

      return Result (1 .. Last);
   end Find_All_Sources;

   ----------
   -- Hash --
   ----------

   function Hash (Name : Name_Id) return Header_Num is
   begin
      return Header_Num (Name mod (Max_Header_Num + 1));
   end Hash;

   function Hash (Name : File_Name_Type) return Header_Num is
   begin
      return Hash (Name_Id (Name));
   end Hash;

   function Hash (Name : Path_Name_Type) return Header_Num is
   begin
      return Hash (Name_Id (Name));
   end Hash;

   function Hash (Project : Project_Id) return Header_Num is
   begin
      if Project = No_Project then
         return Header_Num'First;
      else
         return Hash (Project.Name);
      end if;
   end Hash;

   ---------------
   -- Hex_Image --
   ---------------

   function Hex_Image (Item : Word; Length : Positive := 8) return String is
      Result : String (1 .. Length);
   begin
      Hex_Image (Item, Result);

      return Result;
   end Hex_Image;

   procedure Hex_Image (Item : Word; Result : out String) is
      Chr : constant array (Word range 0 .. 15) of Character :=
              "0123456789abcdef";
      Tmp : Word := Item;
   begin
      for C of reverse Result loop
         C := Chr (Tmp rem 16);
         Tmp := Tmp / 16;
      end loop;

      if Tmp > 0 then
         raise Constraint_Error;
      end if;
   end Hex_Image;

   -----------
   -- Image --
   -----------

   function Image (The_Casing : Casing_Type) return String is
   begin
      return The_Casing_Images (The_Casing).all;
   end Image;

   -----------
   -- Image --
   -----------

   function Image (Kind : Lib_Kind) return String is
   begin
      case Kind is
         when Static      => return "static";
         when Dynamic     => return "dynamic";
         when Relocatable => return "relocatable";
         when Static_Pic  => return "static-pic";
      end case;
   end Image;

   -----------------------------
   -- Is_Standard_GNAT_Naming --
   -----------------------------

   function Is_Standard_GNAT_Naming
     (Naming : Lang_Naming_Data) return Boolean
   is
   begin
      return Get_Name_String (Naming.Spec_Suffix) = ".ads"
        and then Get_Name_String (Naming.Body_Suffix) = ".adb"
        and then Get_Name_String (Naming.Dot_Replacement) = "-";
   end Is_Standard_GNAT_Naming;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize (Tree : Project_Tree_Ref) is
   begin
      if not Initialized then
         Initialized := True;

         GPR.Attr.Initialize;

         --  Add the directory of the GPR tool at the end of the PATH, so that
         --  other GPR tools, such as gprconfig, may be found.

         declare
            Program_Name : constant String := Ada.Command_Line.Command_Name;
            use Ada.Directories;

         begin
            if Program_Name'Length > 0 then
               if Is_Absolute_Path (Program_Name) then
                  Add_To_Path
                    (Containing_Directory (Program_Name),
                     Append => True);

               else
                  Add_To_Path
                    (Get_Current_Dir &
                     Containing_Directory (Program_Name),
                    Append => True);
               end if;
            end if;
         end;
      end if;

      if Tree /= No_Project_Tree then
         Reset (Tree);
      end if;
   end Initialize;

   ------------------
   -- Is_Extending --
   ------------------

   function Is_Extending
     (Extending : Project_Id;
      Extended  : Project_Id) return Boolean
   is
      Proj : Project_Id;

   begin
      Proj := Extending;
      while Proj /= No_Project loop
         if Proj = Extended then
            return True;
         end if;

         Proj := Proj.Extends;
      end loop;

      return False;
   end Is_Extending;

   -----------------
   -- Object_Name --
   -----------------

   function Object_Name
     (Source_File_Name   : File_Name_Type;
      Object_File_Prefix : Name_Id := No_Name;
      Object_File_Suffix : Name_Id := No_Name) return File_Name_Type
   is
      Prefixed_Source_File_Name : File_Name_Type;
   begin
      --  FIXME: SNM: Object_File_Prefix

      --  New_Line;
      --  Put_Line ("FIXME: SNM: Object_File_Prefix, Put_Lines Debuging:");
      --  Put_Line ("Source_File_Name = " &
      --            Get_Name_String (Source_File_Name));
      --  Put_Line ("Object_File_Prefix = " &
      --            Get_Name_String (Object_File_Prefix));
      --  Put_Line ("Object_File_Suffix = " &
      --            Get_Name_String (Object_File_Suffix));
      --  New_Line;

      Get_Name_String (Object_File_Prefix);
      Get_Name_String_And_Append (Source_File_Name);
      Prefixed_Source_File_Name := Name_Find;

      if Object_File_Suffix = No_Name then
         return Extend_Name
           (Prefixed_Source_File_Name, Object_Suffix);
      else
         return Extend_Name
           (Prefixed_Source_File_Name, Get_Name_String (Object_File_Suffix));
      end if;
   end Object_Name;

   function Object_Name
     (Source_File_Name   : File_Name_Type;
      Source_Index       : Int;
      Index_Separator    : Character;
      Object_File_Prefix : Name_Id := No_Name;
      Object_File_Suffix : Name_Id := No_Name) return File_Name_Type
   is
      Index_Img : constant String := Source_Index'Img;
      Last      : Natural;

   begin
      --  FIXME: SNM: Object_File_Prefix
      Get_Name_String (Object_File_Prefix);
      Get_Name_String_And_Append (Source_File_Name);

      Last := Name_Len;
      while Last > 1 and then Name_Buffer (Last) /= '.' loop
         Last := Last - 1;
      end loop;

      if Last > 1 then
         Name_Len := Last - 1;
      end if;

      Add_Char_To_Name_Buffer (Index_Separator);
      Add_Str_To_Name_Buffer (Index_Img (2 .. Index_Img'Last));

      if Object_File_Suffix = No_Name then
         Add_Str_To_Name_Buffer (Object_Suffix);
      else
         Get_Name_String_And_Append (Object_File_Suffix);
      end if;

      return Name_Find;
   end Object_Name;

   ----------------------
   -- Record_Temp_File --
   ----------------------

   procedure Record_Temp_File
     (Shared : Shared_Project_Tree_Data_Access;
      Path   : Path_Name_Type)
   is
   begin
      if Shared = null then
         Temp_Files_Table.Append (Temp_Files, Path);
      else
         Temp_Files_Table.Append (Shared.Private_Part.Temp_Files, Path);
      end if;
   end Record_Temp_File;

   ----------
   -- Free --
   ----------

   procedure Free (List : in out Aggregated_Project_List) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Aggregated_Project, Aggregated_Project_List);
      Tmp : Aggregated_Project_List;
   begin
      while List /= null loop
         Tmp := List.Next;

         Free (List.Tree);

         Unchecked_Free (List);
         List := Tmp;
      end loop;
   end Free;

   ----------------------------
   -- Add_Aggregated_Project --
   ----------------------------

   procedure Add_Aggregated_Project
     (Project : Project_Id;
      Path    : Path_Name_Type)
   is
      Aggregated : Aggregated_Project_List;

   begin
      --  Check if the project is already in the aggregated project list. If it
      --  is, do not add it again.

      Aggregated := Project.Aggregated_Projects;
      while Aggregated /= null loop
         if Path = Aggregated.Path then
            return;
         else
            Aggregated := Aggregated.Next;
         end if;
      end loop;

      Project.Aggregated_Projects := new Aggregated_Project'
        (Path      => Path,
         Project   => No_Project,
         Tree      => null,
         Node_Tree => null,
         Next      => Project.Aggregated_Projects);
   end Add_Aggregated_Project;

   ----------
   -- Free --
   ----------

   procedure Free (Project : in out Project_Id) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Project_Data, Project_Id);

   begin
      if Project /= null then
         Free (Project.Ada_Include_Path);
         Free (Project.Objects_Path);
         Free (Project.Ada_Objects_Path);
         Free (Project.Ada_Objects_Path_No_Libs);
         Free_List (Project.Imported_Projects, Free_Project => False);
         Free_List (Project.All_Imported_Projects, Free_Project => False);
         Free_List (Project.Languages);

         case Project.Qualifier is
            when Aggregate | Aggregate_Library =>
               Free (Project.Aggregated_Projects);

            when others =>
               null;
         end case;

         Unchecked_Free (Project);
      end if;
   end Free;

   ---------------
   -- Free_List --
   ---------------

   procedure Free_List (Languages : in out Language_List) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Language_List_Element, Language_List);
      Tmp : Language_List;
   begin
      while Languages /= null loop
         Tmp := Languages.Next;
         Unchecked_Free (Languages);
         Languages := Tmp;
      end loop;
   end Free_List;

   ---------------
   -- Free_List --
   ---------------

   procedure Free_List (Source : in out Source_Id) is
      procedure Unchecked_Free is new
        Ada.Unchecked_Deallocation (Source_Data, Source_Id);

      Tmp : Source_Id;

   begin
      while Source /= No_Source loop
         Tmp := Source.Next_In_Lang;
         Free_List (Source.Alternate_Languages);

         if Source.Unit /= null
           and then Source.Kind in Spec_Or_Body
         then
            Source.Unit.File_Names (Source.Kind) := null;
         end if;

         Unchecked_Free (Source);
         Source := Tmp;
      end loop;
   end Free_List;

   ---------------
   -- Free_List --
   ---------------

   procedure Free_List
     (List         : in out Project_List;
      Free_Project : Boolean)
   is
      procedure Unchecked_Free is new
        Ada.Unchecked_Deallocation (Project_List_Element, Project_List);

      Tmp : Project_List;

   begin
      while List /= null loop
         Tmp := List.Next;

         if Free_Project then
            Free (List.Project);
         end if;

         Unchecked_Free (List);
         List := Tmp;
      end loop;
   end Free_List;

   ---------------
   -- Free_List --
   ---------------

   procedure Free_List (Languages : in out Language_Ptr) is
      procedure Unchecked_Free is new
        Ada.Unchecked_Deallocation (Language_Data, Language_Ptr);

      Tmp : Language_Ptr;

   begin
      while Languages /= null loop
         Tmp := Languages.Next;
         Free_List (Languages.First_Source);
         Unchecked_Free (Languages);
         Languages := Tmp;
      end loop;
   end Free_List;

   -----------
   -- Label --
   -----------

   function Label (Section : Section_Type) return String is
   begin
      case Section is
         when Setup =>
            return "Setup";
         when Compile =>
            return "Compile";
         when Build_Libraries =>
            return "Build Libraries";
         when Bind =>
            return "Bind";
         when Link =>
            return "Link";
      end case;
   end Label;

   --------------------------
   -- Reset_Units_In_Table --
   --------------------------

   procedure Reset_Units_In_Table (Table : in out Units_Htable.Instance) is
      Unit : Unit_Index;

   begin
      Unit := Units_Htable.Get_First (Table);
      while Unit /= No_Unit_Index loop
         if Unit.File_Names (Spec) /= null then
            Unit.File_Names (Spec).Unit := No_Unit_Index;
         end if;

         if Unit.File_Names (Impl) /= null then
            Unit.File_Names (Impl).Unit := No_Unit_Index;
         end if;

         Unit := Units_Htable.Get_Next (Table);
      end loop;
   end Reset_Units_In_Table;

   ----------------
   -- Free_Units --
   ----------------

   procedure Free_Units (Table : in out Units_Htable.Instance) is
      procedure Unchecked_Free is new
        Ada.Unchecked_Deallocation (Unit_Data, Unit_Index);

      Unit : Unit_Index;

   begin
      Unit := Units_Htable.Get_First (Table);
      while Unit /= No_Unit_Index loop

         --  We cannot reset Unit.File_Names (Impl or Spec).Unit here as
         --  Source_Data buffer is freed by the following instruction
         --  Free_List (Tree.Projects, Free_Project => True);

         Unchecked_Free (Unit);
         Unit := Units_Htable.Get_Next (Table);
      end loop;

      Units_Htable.Reset (Table);
   end Free_Units;

   ----------
   -- Free --
   ----------

   procedure Free (Tree : in out Project_Tree_Ref) is
      procedure Unchecked_Free is new
        Ada.Unchecked_Deallocation
          (Project_Tree_Data, Project_Tree_Ref);

      procedure Unchecked_Free is new
        Ada.Unchecked_Deallocation
          (Project_Tree_Appdata'Class, Project_Tree_Appdata_Access);

   begin
      if Tree /= null then
         if Tree.Is_Root_Tree then
            Name_List_Table.Free        (Tree.Shared.Name_Lists);
            Number_List_Table.Free      (Tree.Shared.Number_Lists);
            String_Element_Table.Free   (Tree.Shared.String_Elements);
            Variable_Element_Table.Free (Tree.Shared.Variable_Elements);
            Array_Element_Table.Free    (Tree.Shared.Array_Elements);
            Array_Table.Free            (Tree.Shared.Arrays);
            Package_Table.Free          (Tree.Shared.Packages);
            Temp_Files_Table.Free       (Tree.Shared.Private_Part.Temp_Files);
         end if;

         if Tree.Appdata /= null then
            Free (Tree.Appdata.all);
            Unchecked_Free (Tree.Appdata);
         end if;

         Source_Paths_Htable.Reset (Tree.Source_Paths_HT);
         Source_Files_Htable.Reset (Tree.Source_Files_HT);

         Reset_Units_In_Table (Tree.Units_HT);
         Free_List (Tree.Projects, Free_Project => True);
         Free_Units (Tree.Units_HT);

         Unchecked_Free (Tree);
      end if;
   end Free;

   ------------------------------
   -- Languages_Are_Restricted --
   ------------------------------

   function Languages_Are_Restricted return Boolean is
   begin
      return Restricted_Languages /= null;
   end Languages_Are_Restricted;

   -----------
   -- Reset --
   -----------

   procedure Reset (Tree : Project_Tree_Ref) is
   begin
      --  Visible tables

      if Tree.Is_Root_Tree then

         --  We cannot use 'Access here:
         --    "illegal attribute for discriminant-dependent component"
         --  However, we know this is valid since Shared and Shared_Data have
         --  the same lifetime and will always exist concurrently.

         Tree.Shared := Tree.Shared_Data'Unrestricted_Access;
         Number_List_Table.Init      (Tree.Shared.Number_Lists);
         String_Element_Table.Init   (Tree.Shared.String_Elements);
         Variable_Element_Table.Init (Tree.Shared.Variable_Elements);
         Array_Element_Table.Init    (Tree.Shared.Array_Elements);
         Array_Table.Init            (Tree.Shared.Arrays);
         Package_Table.Init          (Tree.Shared.Packages);

         --  As Ada_Runtime_Dir is the key for caching various Ada language
         --  data, reset it so that the cached values are no longer used.

         --  Tree.Shared.Ada_Runtime_Dir := No_Name;

         --  Create Dot_String_List

         String_Element_Table.Append
           (Tree.Shared.String_Elements,
            String_Element'
              (Value         => The_Dot_String,
               Index         => 0,
               Display_Value => The_Dot_String,
               Location      => No_Location,
               Next          => Nil_String));
         Tree.Shared.Dot_String_List :=
           String_Element_Table.Last (Tree.Shared.String_Elements);

         --  Private part table

         Temp_Files_Table.Init (Tree.Shared.Private_Part.Temp_Files);

         Tree.Shared.Private_Part.Current_Source_Path_File := No_Path;
         Tree.Shared.Private_Part.Current_Object_Path_File := No_Path;
      end if;

      Source_Paths_Htable.Reset    (Tree.Source_Paths_HT);
      Source_Files_Htable.Reset    (Tree.Source_Files_HT);
      Replaced_Source_HTable.Reset (Tree.Replaced_Sources);

      Tree.Replaced_Source_Number := 0;

      Reset_Units_In_Table (Tree.Units_HT);
      Free_List (Tree.Projects, Free_Project => True);
      Free_Units (Tree.Units_HT);
   end Reset;

   -------------------------------------
   -- Set_Current_Object_Path_File_Of --
   -------------------------------------

   procedure Set_Current_Object_Path_File_Of
     (Shared : Shared_Project_Tree_Data_Access;
      To     : Path_Name_Type)
   is
   begin
      Shared.Private_Part.Current_Object_Path_File := To;
   end Set_Current_Object_Path_File_Of;

   -------------------------------------
   -- Set_Current_Source_Path_File_Of --
   -------------------------------------

   procedure Set_Current_Source_Path_File_Of
     (Shared : Shared_Project_Tree_Data_Access;
      To     : Path_Name_Type)
   is
   begin
      Shared.Private_Part.Current_Source_Path_File := To;
   end Set_Current_Source_Path_File_Of;

   -----------------------
   -- Set_Path_File_Var --
   -----------------------

   procedure Set_Path_File_Var (Name : String; Value : String) is
   begin
      Setenv (Name, Value);
   end Set_Path_File_Var;

   -------------------
   -- Switches_Name --
   -------------------

   function Switches_Name
     (Source_File_Name : File_Name_Type) return File_Name_Type
   is
   begin
      return Extend_Name (Source_File_Name, Switches_Dependency_Suffix);
   end Switches_Name;

   -----------
   -- Value --
   -----------

   function Value (Image : String) return Casing_Type is
   begin
      for Casing in The_Casing_Images'Range loop
         if To_Lower (Image) = To_Lower (The_Casing_Images (Casing).all) then
            return Casing;
         end if;
      end loop;

      raise Constraint_Error;
   end Value;

   ---------------------
   -- Has_Ada_Sources --
   ---------------------

   function Has_Ada_Sources (Data : Project_Id) return Boolean is
      Lang : Language_Ptr;

   begin
      Lang := Data.Languages;
      while Lang /= No_Language_Index loop
         if Lang.Name = Name_Ada then
            return Lang.First_Source /= No_Source;
         end if;
         Lang := Lang.Next;
      end loop;

      return False;
   end Has_Ada_Sources;

   ------------------------
   -- Contains_ALI_Files --
   ------------------------

   function Contains_ALI_Files (Dir : Path_Name_Type) return Boolean is
      Dir_Name : constant String := Get_Name_String (Dir);
      Direct   : Dir_Type;
      Name     : String (1 .. 1_000);
      Last     : Natural;
      Result   : Boolean := False;

   begin
      Open (Direct, Dir_Name);

      --  For each file in the directory, check if it is an ALI file

      loop
         Read (Direct, Name, Last);
         exit when Last = 0;
         --  Canonical_Case_File_Name (Name (1 .. Last));
         Result := Last >= 5 and then Name (Last - 3 .. Last) = ".ali";
         exit when Result;
      end loop;

      Close (Direct);
      return Result;

   exception
      --  If there is any problem, close the directory if open and return True.
      --  The library directory will be added to the path.

      when others =>
         if Is_Open (Direct) then
            Close (Direct);
         end if;

         return True;
   end Contains_ALI_Files;

   --------------------------
   -- Get_Object_Directory --
   --------------------------

   function Get_Object_Directory
     (Project             : Project_Id;
      Including_Libraries : Boolean;
      Only_If_Ada         : Boolean := False) return Path_Name_Type
   is
   begin
      if (Project.Library and then Including_Libraries)
        or else
          (Project.Object_Directory /= No_Path_Information
            and then (not Including_Libraries or else not Project.Library))
      then
         --  For a library project, add the library ALI directory if there is
         --  no object directory or if the library ALI directory contains ALI
         --  files; otherwise add the object directory.

         if Project.Library then
            if Project.Object_Directory = No_Path_Information
              or else
                (Including_Libraries
                  and then
                    Contains_ALI_Files (Project.Library_ALI_Dir.Display_Name))
            then
               return Project.Library_ALI_Dir.Display_Name;
            else
               return Project.Object_Directory.Display_Name;
            end if;

            --  For a non-library project, add object directory if it is not a
            --  virtual project, and if there are Ada sources in the project or
            --  one of the projects it extends. If there are no Ada sources,
            --  adding the object directory could disrupt the order of the
            --  object dirs in the path.

         elsif not Project.Virtual then
            declare
               Add_Object_Dir : Boolean;
               Prj            : Project_Id;

            begin
               Add_Object_Dir := not Only_If_Ada;
               Prj := Project;
               while not Add_Object_Dir and then Prj /= No_Project loop
                  if Has_Ada_Sources (Prj) then
                     Add_Object_Dir := True;
                  else
                     Prj := Prj.Extends;
                  end if;
               end loop;

               if Add_Object_Dir then
                  return Project.Object_Directory.Display_Name;
               end if;
            end;
         end if;
      end if;

      return No_Path;
   end Get_Object_Directory;

   -----------------------------------
   -- Ultimate_Extending_Project_Of --
   -----------------------------------

   function Ultimate_Extending_Project_Of
     (Proj : Project_Id; Before : Project_Id := No_Project) return Project_Id
   is
      Prj : Project_Id := Proj;
   begin
      if Prj /= No_Project then
         while Prj.Extended_By not in No_Project | Before loop
            Prj := Prj.Extended_By;
         end loop;
      end if;

      return Prj;
   end Ultimate_Extending_Project_Of;

   -----------------------------------
   -- Compute_All_Imported_Projects --
   -----------------------------------

   procedure Compute_All_Imported_Projects
     (Root_Project : Project_Id;
      Tree         : Project_Tree_Ref)
   is
      procedure Analyze_Tree
        (Local_Root : Project_Id;
         Local_Tree : Project_Tree_Ref;
         Context    : Project_Context);
      --  Process Project and all its aggregated project to analyze their own
      --  imported projects.

      ------------------
      -- Analyze_Tree --
      ------------------

      procedure Analyze_Tree
        (Local_Root : Project_Id;
         Local_Tree : Project_Tree_Ref;
         Context    : Project_Context)
      is
         pragma Unreferenced (Local_Root);

         Project : Project_Id;

         procedure Recursive_Add
           (Prj     : Project_Id;
            Tree    : Project_Tree_Ref;
            Context : Project_Context;
            Dummy   : in out Boolean);
         --  Recursively add the projects imported by project Project, but not
         --  those that are extended.

         -------------------
         -- Recursive_Add --
         -------------------

         procedure Recursive_Add
           (Prj     : Project_Id;
            Tree    : Project_Tree_Ref;
            Context : Project_Context;
            Dummy   : in out Boolean)
         is
            pragma Unreferenced (Tree);

            List : Project_List;
            Prj2 : Project_Id;

         begin
            --  A project is not importing itself

            Prj2 := Ultimate_Extending_Project_Of (Prj);

            if Project /= Prj2 then

               --  Check that the project is not already in the list. We know
               --  the one passed to Recursive_Add have never been visited
               --  before, but the one passed it are the extended projects.

               List := Project.All_Imported_Projects;
               while List /= null loop
                  if List.Project = Prj2 then
                     return;
                  end if;

                  List := List.Next;
               end loop;

               --  Add it to the list

               Project.All_Imported_Projects :=
                 new Project_List_Element'
                   (Project               => Prj2,
                    From_Encapsulated_Lib =>
                      Context.From_Encapsulated_Lib
                        or else Analyze_Tree.Context.From_Encapsulated_Lib,
                    Next                  => Project.All_Imported_Projects);
            end if;
         end Recursive_Add;

         procedure For_All_Projects is
           new For_Every_Project_Imported_Context (Boolean, Recursive_Add);

         Dummy : Boolean := False;
         List  : Project_List;

      begin
         List := Local_Tree.Projects;
         while List /= null loop
            Project := List.Project;
            Free_List
              (Project.All_Imported_Projects, Free_Project => False);
            For_All_Projects
              (Project, Local_Tree, Dummy, Include_Aggregated => False);
            List := List.Next;
         end loop;
      end Analyze_Tree;

      procedure For_Aggregates is
        new For_Project_And_Aggregated_Context (Analyze_Tree);

   --  Start of processing for Compute_All_Imported_Projects

   begin
      For_Aggregates (Root_Project, Tree);
   end Compute_All_Imported_Projects;

   -------------------
   -- Is_Compilable --
   -------------------

   function Is_Compilable (Source : Source_Id) return Boolean is
   begin
      case Source.Compilable is
         when Unknown =>
            if (Source.Language.Config.Compiler_Driver not in
                  No_File | Empty_File
                or else Gprls_Mode)
              and then not Source.Locally_Removed
              and then (Source.Language.Config.Kind /= File_Based
                         or else Source.Kind /= Spec)
            then
               --  Do not modify Source.Compilable before the source record
               --  has been initialized.

               if Source.Source_TS /= Empty_Time_Stamp then
                  Source.Compilable := Yes;
               end if;

               return True;

            else
               if Source.Source_TS /= Empty_Time_Stamp then
                  Source.Compilable := No;
               end if;

               return False;
            end if;

         when Yes =>
            return True;

         when No =>
            return False;
      end case;
   end Is_Compilable;

   ------------------------------
   -- Object_To_Global_Archive --
   ------------------------------

   function Object_To_Global_Archive (Source : Source_Id) return Boolean is
   begin
      return Source.Language.Config.Kind = File_Based
        and then Source.Kind = Impl
        and then Source.Language.Config.Objects_Linked
        and then Is_Compilable (Source)
        and then Source.Language.Config.Object_Generated;
   end Object_To_Global_Archive;

   ----------------------------
   -- Get_Language_From_Name --
   ----------------------------

   function Get_Language_From_Name
     (Project : Project_Id;
      Name    : String) return Language_Ptr
   is
      N      : Name_Id;
      Result : Language_Ptr;

   begin
      N := Get_Lower_Name_Id (Name);

      Result := Project.Languages;
      while Result /= No_Language_Index loop
         if Result.Name = N then
            return Result;
         end if;

         Result := Result.Next;
      end loop;

      return No_Language_Index;
   end Get_Language_From_Name;

   ----------------
   -- Other_Part --
   ----------------

   function Other_Part (Source : Source_Id) return Source_Id is
   begin
      if Source.Unit /= No_Unit_Index then
         case Source.Kind is
            when Impl =>
               return Source.Unit.File_Names (Spec);
            when Spec =>
               return Source.Unit.File_Names (Impl);
            when Sep =>
               return No_Source;
         end case;
      else
         return No_Source;
      end if;
   end Other_Part;

   ------------------
   -- Create_Flags --
   ------------------

   function Create_Flags
     (Report_Error               : Error_Handler;
      When_No_Sources            : Error_Warning;
      Require_Sources_Other_Lang : Boolean       := True;
      Allow_Duplicate_Basenames  : Boolean       := True;
      Compiler_Driver_Mandatory  : Boolean       := False;
      Error_On_Unknown_Language  : Boolean       := True;
      Require_Obj_Dirs           : Error_Warning := Error;
      Allow_Invalid_External     : Error_Warning := Error;
      Missing_Project_Files      : Error_Warning := Error;
      Missing_Source_Files       : Error_Warning := Error;
      Ignore_Missing_With        : Boolean       := False;
      Check_Configuration_Only   : Boolean       := False)
      return Processing_Flags
   is
   begin
      return Processing_Flags'
        (Report_Error               => Report_Error,
         When_No_Sources            => When_No_Sources,
         Require_Sources_Other_Lang => Require_Sources_Other_Lang,
         Allow_Duplicate_Basenames  => Allow_Duplicate_Basenames,
         Error_On_Unknown_Language  => Error_On_Unknown_Language,
         Compiler_Driver_Mandatory  => Compiler_Driver_Mandatory,
         Require_Obj_Dirs           => Require_Obj_Dirs,
         Allow_Invalid_External     => Allow_Invalid_External,
         Missing_Project_Files      => Missing_Project_Files,
         Missing_Source_Files       => Missing_Source_Files,
         Ignore_Missing_With        => Ignore_Missing_With,
         Incomplete_Withs           => False,
         Check_Configuration_Only   => Check_Configuration_Only);
   end Create_Flags;

   ------------
   -- Length --
   ------------

   function Length
     (Table : Name_List_Table.Instance;
      List  : Name_List_Index) return Natural
   is
      Count : Natural := 0;
      Tmp   : Name_List_Index;

   begin
      Tmp := List;
      while Tmp /= No_Name_List loop
         Count := Count + 1;
         Tmp := Table.Table (Tmp).Next;
      end loop;

      return Count;
   end Length;

   ------------------
   -- Debug_Output --
   ------------------

   procedure Debug_Output (Str : String) is
   begin
      if Current_Verbosity > Default then
         Set_Standard_Error;
         Write_Line ((1 .. Debug_Level * 2 => ' ') & Str);
         Set_Standard_Output;
      end if;
   end Debug_Output;

   ------------------
   -- Debug_Indent --
   ------------------

   procedure Debug_Indent is
   begin
      if Current_Verbosity = High then
         Set_Standard_Error;
         Write_Str ((1 .. Debug_Level * 2 => ' '));
         Set_Standard_Output;
      end if;
   end Debug_Indent;

   ------------------
   -- Debug_Output --
   ------------------

   procedure Debug_Output (Str : String; Str2 : Name_Id) is
   begin
      if Current_Verbosity > Default then
         Debug_Indent;
         Set_Standard_Error;
         Write_Str (Str);

         if Str2 = No_Name then
            Write_Line (" <no_name>");
         else
            Write_Line (" """ & Get_Name_String (Str2) & '"');
         end if;

         Set_Standard_Output;
      end if;
   end Debug_Output;

   ---------------------------
   -- Debug_Increase_Indent --
   ---------------------------

   procedure Debug_Increase_Indent
     (Str : String := ""; Str2 : Name_Id := No_Name)
   is
   begin
      if Str2 /= No_Name then
         Debug_Output (Str, Str2);
      else
         Debug_Output (Str);
      end if;
      Debug_Level := Debug_Level + 1;
   end Debug_Increase_Indent;

   ---------------------------
   -- Debug_Decrease_Indent --
   ---------------------------

   procedure Debug_Decrease_Indent (Str : String := "") is
   begin
      if Debug_Level > 0 then
         Debug_Level := Debug_Level - 1;
      end if;

      if Str /= "" then
         Debug_Output (Str);
      end if;
   end Debug_Decrease_Indent;

   ----------------
   -- Debug_Name --
   ----------------

   function Debug_Name (Tree : Project_Tree_Ref) return Name_Id is
      P : Project_List;

   begin
      Set_Name_Buffer ("Tree [");

      P := Tree.Projects;
      while P /= null loop
         if P /= Tree.Projects then
            Add_Char_To_Name_Buffer (',');
         end if;

         Add_Str_To_Name_Buffer (Get_Name_String (P.Project.Name));

         P := P.Next;
      end loop;

      Add_Char_To_Name_Buffer (']');

      return Name_Find;
   end Debug_Name;

   --------------
   -- Distance --
   --------------

   function Distance (L, R : String) return Natural is
      D : array (L'First - 1 .. L'Last, R'First - 1 .. R'Last) of Natural;
   begin
      for I in D'Range (1) loop
         D (I, D'First (2)) := I;
      end loop;

      for I in D'Range (2) loop
         D (D'First (1), I) := I;
      end loop;

      for J in R'Range loop
         for I in L'Range loop
            D (I, J) :=
              Natural'Min
                (Natural'Min (D (I - 1, J), D (I, J - 1)) + 1,
                 D (I - 1, J - 1) + (if L (I) = R (J) then 0 else 1));

            if J > R'First and then I > L'First
              and then R (J) = L (I - 1) and then R (J - 1) = L (I)
            then
               D (I, J) := Natural'Min (D (I, J), D (I - 2, J - 2) + 1);
            end if;
         end loop;
      end loop;

      return D (L'Last, R'Last);
   end Distance;

   ----------
   -- Free --
   ----------

   procedure Free (Tree : in out Project_Tree_Appdata) is
      pragma Unreferenced (Tree);
   begin
      null;
   end Free;

   --------------------------------
   -- For_Project_And_Aggregated --
   --------------------------------

   procedure For_Project_And_Aggregated
     (Root_Project : Project_Id;
      Root_Tree    : Project_Tree_Ref)
   is
      Agg : Aggregated_Project_List;

   begin
      Action (Root_Project, Root_Tree);

      if Root_Project.Qualifier in Aggregate_Project then
         Agg := Root_Project.Aggregated_Projects;
         while Agg /= null loop
            For_Project_And_Aggregated (Agg.Project, Agg.Tree);
            Agg := Agg.Next;
         end loop;
      end if;
   end For_Project_And_Aggregated;

   ----------------------------------------
   -- For_Project_And_Aggregated_Context --
   ----------------------------------------

   procedure For_Project_And_Aggregated_Context
     (Root_Project : Project_Id;
      Root_Tree    : Project_Tree_Ref)
   is

      procedure Recursive_Process
        (Project : Project_Id;
         Tree    : Project_Tree_Ref;
         Context : Project_Context);
      --  Process Project and all aggregated projects recursively

      -----------------------
      -- Recursive_Process --
      -----------------------

      procedure Recursive_Process
        (Project : Project_Id;
         Tree    : Project_Tree_Ref;
         Context : Project_Context)
      is
         Agg : Aggregated_Project_List;
         Ctx : Project_Context;

      begin
         Action (Project, Tree, Context);

         if Project.Qualifier in Aggregate_Project then
            Ctx :=
              (In_Aggregate_Lib      => Project.Qualifier = Aggregate_Library,
               From_Encapsulated_Lib =>
                 Context.From_Encapsulated_Lib
                   or else Project.Standalone_Library = Encapsulated);

            Agg := Project.Aggregated_Projects;
            while Agg /= null loop
               Recursive_Process (Agg.Project, Agg.Tree, Ctx);
               Agg := Agg.Next;
            end loop;
         end if;
      end Recursive_Process;

   --  Start of processing for For_Project_And_Aggregated_Context

   begin
      Recursive_Process
        (Root_Project, Root_Tree, Project_Context'(False, False));
   end For_Project_And_Aggregated_Context;

   --------------------------
   -- Set_Require_Obj_Dirs --
   --------------------------

   procedure Set_Require_Obj_Dirs
     (Flags : in out Processing_Flags;
      Value : Error_Warning)
   is
   begin
      Flags.Require_Obj_Dirs := Value;
   end Set_Require_Obj_Dirs;

   -----------------------------
   -- Set_Ignore_Missing_With --
   -----------------------------

   procedure Set_Ignore_Missing_With
     (Flags : in out Processing_Flags;
      Value : Boolean)
   is
   begin
      Flags.Ignore_Missing_With := Value;
   end Set_Ignore_Missing_With;

   ----------------------------------
   -- Set_Check_Configuration_Only --
   ----------------------------------

   procedure Set_Check_Configuration_Only
     (Flags : in out Processing_Flags;
      Value : Boolean)
   is
   begin
      Flags.Check_Configuration_Only := Value;
   end Set_Check_Configuration_Only;

   ------------------------------
   -- Set_Missing_Source_Files --
   ------------------------------

   procedure Set_Missing_Source_Files
     (Flags : in out Processing_Flags;
      Value : Error_Warning)
   is
   begin
      Flags.Missing_Source_Files := Value;
   end Set_Missing_Source_Files;

begin
   Temp_Files_Table.Init (Temp_Files);
end GPR;
