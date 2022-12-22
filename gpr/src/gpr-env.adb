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

with Ada.Strings.Unbounded;
with Ada.Text_IO; use Ada.Text_IO;

with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.HTable;
with GNAT.String_Split;

with GPR.Opt;
with GPR.Com;     use GPR.Com;
with GPR.Names;   use GPR.Names;
with GPR.Osint;   use GPR.Osint;
with GPR.Output;  use GPR.Output;
with GPR.Tempdir;
with GPR.Util;    use GPR.Util;

package body GPR.Env is

   Buffer_Initial : constant := 1_000;
   --  Initial arbitrary size of buffers

   No_Project_Default_Dir : constant String := "-";
   --  Indicator in the project path to indicate that the default search
   --  directories should not be added to the path

   -----------------------
   -- Local Subprograms --
   -----------------------

   package Source_Path_Table is new GNAT.Dynamic_Tables
     (Table_Component_Type => Name_Id,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 50,
      Table_Increment      => 100);
   --  A table to store the source dirs before creating the source path file

   package Object_Path_Table is new GNAT.Dynamic_Tables
     (Table_Component_Type => Path_Name_Type,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 50,
      Table_Increment      => 100);
   --  A table to store the object dirs, before creating the object path file

   procedure Add_To_Buffer
     (S           : String;
      Buffer      : in out String_Access;
      Buffer_Last : in out Natural);
   --  Add a string to Buffer, extending Buffer if needed

   procedure Add_To_Path
     (Source_Dirs : String_List_Id;
      Shared      : Shared_Project_Tree_Data_Access;
      Buffer      : in out String_Access;
      Buffer_Last : in out Natural);
   --  Add to Ada_Path_Buffer all the source directories in string list
   --  Source_Dirs, if any.

   procedure Add_To_Path
     (Dir         : String;
      Buffer      : in out String_Access;
      Buffer_Last : in out Natural);
   --  If Dir is not already in the global variable Ada_Path_Buffer, add it.
   --  If Buffer_Last /= 0, prepend a Path_Separator character to Path.

   procedure Add_To_Source_Path
     (Source_Dirs  : String_List_Id;
      Shared       : Shared_Project_Tree_Data_Access;
      Source_Paths : in out Source_Path_Table.Instance);
   --  Add to Ada_Path_B all the source directories in string list
   --  Source_Dirs, if any. Increment Ada_Path_Length.

   procedure Add_To_Object_Path
     (Object_Dir   : Path_Name_Type;
      Object_Paths : in out Object_Path_Table.Instance);
   --  Add Object_Dir to object path table. Make sure it is not duplicate
   --  and it is the last one in the current table.

   function To_Vector (Path : String) return Util.String_Vectors.Vector;

   ----------------------
   -- Ada_Include_Path --
   ----------------------

   function Ada_Include_Path
     (Project   : Project_Id;
      In_Tree   : Project_Tree_Ref;
      Recursive : Boolean := False) return String
   is
      Buffer      : String_Access;
      Buffer_Last : Natural := 0;

      procedure Add
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Boolean);
      --  Add source dirs of Project to the path

      ---------
      -- Add --
      ---------

      procedure Add
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Boolean)
      is
      begin
         Add_To_Path
           (Project.Source_Dirs, In_Tree.Shared, Buffer, Buffer_Last);
      end Add;

      procedure For_All_Projects is
        new For_Every_Project_Imported (Boolean, Add);

      Dummy : Boolean := False;

   --  Start of processing for Ada_Include_Path

   begin
      if Recursive then

         --  If it is the first time we call this function for this project,
         --  compute the source path.

         if Project.Ada_Include_Path = null then
            Buffer := new String (1 .. Buffer_Initial);
            For_All_Projects
              (Project, In_Tree, Dummy, Include_Aggregated => True);
            Project.Ada_Include_Path := new String'(Buffer (1 .. Buffer_Last));
            Free (Buffer);
         end if;

         return Project.Ada_Include_Path.all;

      else
         Buffer := new String (1 .. Buffer_Initial);
         Add_To_Path
           (Project.Source_Dirs, In_Tree.Shared, Buffer, Buffer_Last);

         declare
            Result : constant String := Buffer (1 .. Buffer_Last);
         begin
            Free (Buffer);
            return Result;
         end;
      end if;
   end Ada_Include_Path;

   ----------------------
   -- Ada_Objects_Path --
   ----------------------

   function Ada_Objects_Path
     (Project             : Project_Id;
      In_Tree             : Project_Tree_Ref;
      Including_Libraries : Boolean := True) return String_Access
   is
      Buffer      : String_Access;
      Buffer_Last : Natural := 0;

      procedure Add
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Boolean);
      --  Add all the object directories of a project to the path

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
                     Including_Libraries => Including_Libraries,
                     Only_If_Ada         => False);
      begin
         if Path /= No_Path then
            Add_To_Path (Get_Name_String (Path), Buffer, Buffer_Last);
         end if;
      end Add;

      procedure For_All_Projects is
        new For_Every_Project_Imported (Boolean, Add);

      Dummy : Boolean := False;

      Result : String_Access;

   --  Start of processing for Ada_Objects_Path

   begin
      --  If it is the first time we call this function for
      --  this project, compute the objects path

      if Including_Libraries and then Project.Ada_Objects_Path /= null then
         return Project.Ada_Objects_Path;

      elsif not Including_Libraries
        and then Project.Ada_Objects_Path_No_Libs /= null
      then
         return Project.Ada_Objects_Path_No_Libs;

      else
         Buffer := new String (1 .. Buffer_Initial);
         For_All_Projects (Project, In_Tree, Dummy);
         Result := new String'(Buffer (1 .. Buffer_Last));
         Free (Buffer);

         if Including_Libraries then
            Project.Ada_Objects_Path := Result;
         else
            Project.Ada_Objects_Path_No_Libs := Result;
         end if;

         return Result;
      end if;
   end Ada_Objects_Path;

   -------------------
   -- Add_To_Buffer --
   -------------------

   procedure Add_To_Buffer
     (S           : String;
      Buffer      : in out String_Access;
      Buffer_Last : in out Natural)
   is
      Last : constant Natural := Buffer_Last + S'Length;

   begin
      while Last > Buffer'Last loop
         declare
            New_Buffer : constant String_Access :=
                           new String (1 .. 2 * Buffer'Last);
         begin
            New_Buffer (1 .. Buffer_Last) := Buffer (1 .. Buffer_Last);
            Free (Buffer);
            Buffer := New_Buffer;
         end;
      end loop;

      Buffer (Buffer_Last + 1 .. Last) := S;
      Buffer_Last := Last;
   end Add_To_Buffer;

   ------------------------
   -- Add_To_Object_Path --
   ------------------------

   procedure Add_To_Object_Path
     (Object_Dir   : Path_Name_Type;
      Object_Paths : in out Object_Path_Table.Instance)
   is
   begin
      --  Check if the directory is already in the table

      for Index in
        Object_Path_Table.First .. Object_Path_Table.Last (Object_Paths)
      loop
         --  If it is, remove it, and add it as the last one

         if Object_Paths.Table (Index) = Object_Dir then
            for Index2 in
              Index + 1 .. Object_Path_Table.Last (Object_Paths)
            loop
               Object_Paths.Table (Index2 - 1) := Object_Paths.Table (Index2);
            end loop;

            Object_Paths.Table
              (Object_Path_Table.Last (Object_Paths)) := Object_Dir;
            return;
         end if;
      end loop;

      --  The directory is not already in the table, add it

      Object_Path_Table.Append (Object_Paths, Object_Dir);
   end Add_To_Object_Path;

   -----------------
   -- Add_To_Path --
   -----------------

   procedure Add_To_Path
     (Source_Dirs : String_List_Id;
      Shared      : Shared_Project_Tree_Data_Access;
      Buffer      : in out String_Access;
      Buffer_Last : in out Natural)
   is
      Current    : String_List_Id;
      Source_Dir : String_Element;
   begin
      Current := Source_Dirs;
      while Current /= Nil_String loop
         Source_Dir := Shared.String_Elements.Table (Current);
         Add_To_Path (Get_Name_String (Source_Dir.Display_Value),
                      Buffer, Buffer_Last);
         Current := Source_Dir.Next;
      end loop;
   end Add_To_Path;

   procedure Add_To_Path
     (Dir         : String;
      Buffer      : in out String_Access;
      Buffer_Last : in out Natural)
   is
      Len        : Natural;
      New_Buffer : String_Access;
      Min_Len    : Natural;

      function Is_Present (Path : String; Dir : String) return Boolean;
      --  Return True if Dir is part of Path

      ----------------
      -- Is_Present --
      ----------------

      function Is_Present (Path : String; Dir : String) return Boolean is
         Last : constant Integer := Path'Last - Dir'Length + 1;

      begin
         for J in Path'First .. Last loop

            --  Note: the order of the conditions below is important, since
            --  it ensures a minimal number of string comparisons.

            if (J = Path'First or else Path (J - 1) = Path_Separator)
              and then
                (J + Dir'Length > Path'Last
                  or else Path (J + Dir'Length) = Path_Separator)
              and then Dir = Path (J .. J + Dir'Length - 1)
            then
               return True;
            end if;
         end loop;

         return False;
      end Is_Present;

   --  Start of processing for Add_To_Path

   begin
      if Is_Present (Buffer (1 .. Buffer_Last), Dir) then

         --  Dir is already in the path, nothing to do

         return;
      end if;

      Min_Len := Buffer_Last + Dir'Length;

      if Buffer_Last > 0 then

         --  Add 1 for the Path_Separator character

         Min_Len := Min_Len + 1;
      end if;

      --  If Ada_Path_Buffer is too small, increase it

      Len := Buffer'Last;

      if Len < Min_Len then
         loop
            Len := Len * 2;
            exit when Len >= Min_Len;
         end loop;

         New_Buffer := new String (1 .. Len);
         New_Buffer (1 .. Buffer_Last) := Buffer (1 .. Buffer_Last);
         Free (Buffer);
         Buffer := New_Buffer;
      end if;

      if Buffer_Last > 0 then
         Buffer_Last := Buffer_Last + 1;
         Buffer (Buffer_Last) := Path_Separator;
      end if;

      Buffer (Buffer_Last + 1 .. Buffer_Last + Dir'Length) := Dir;
      Buffer_Last := Buffer_Last + Dir'Length;
   end Add_To_Path;

   ------------------------
   -- Add_To_Source_Path --
   ------------------------

   procedure Add_To_Source_Path
     (Source_Dirs  : String_List_Id;
      Shared       : Shared_Project_Tree_Data_Access;
      Source_Paths : in out Source_Path_Table.Instance)
   is
      Current    : String_List_Id;
      Source_Dir : String_Element;
      Add_It     : Boolean;

   begin
      --  Add each source directory

      Current := Source_Dirs;
      while Current /= Nil_String loop
         Source_Dir := Shared.String_Elements.Table (Current);
         Add_It := True;

         --  Check if the source directory is already in the table

         for Index in
           Source_Path_Table.First .. Source_Path_Table.Last (Source_Paths)
         loop
            --  If it is already, no need to add it

            if Source_Paths.Table (Index) = Source_Dir.Value then
               Add_It := False;
               exit;
            end if;
         end loop;

         if Add_It then
            Source_Path_Table.Append (Source_Paths, Source_Dir.Display_Value);
         end if;

         --  Next source directory

         Current := Source_Dir.Next;
      end loop;
   end Add_To_Source_Path;

   --------------------------------
   -- Create_Config_Pragmas_File --
   --------------------------------

   procedure Create_Config_Pragmas_File
     (For_Project : Project_Id;
      In_Tree     : Project_Tree_Ref)
   is
      type Naming_Id is new Nat;
      package Naming_Table is new GNAT.Dynamic_Tables
        (Table_Component_Type => Lang_Naming_Data,
         Table_Index_Type     => Naming_Id,
         Table_Low_Bound      => 1,
         Table_Initial        => 5,
         Table_Increment      => 100);

      Default_Naming : constant Naming_Id := Naming_Table.First;
      Namings        : Naming_Table.Instance;
      --  Table storing the naming data for gnatmake/gprmake

      Buffer      : String_Access := new String (1 .. Buffer_Initial);
      Buffer_Last : Natural := 0;

      File_Name : Path_Name_Type  := No_Path;
      File      : File_Descriptor := Invalid_FD;

      Current_Naming : Naming_Id;

      procedure Check
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         State   : in out Integer);
      --  Recursive procedure that put in the config pragmas file any non
      --  standard naming schemes, if it is not already in the file, then call
      --  itself for any imported project.

      procedure Put (Source : Source_Id);
      --  Put an SFN pragma in the temporary file

      procedure Put (S : String);
      procedure Put_Line (S : String);
      --  Output procedures, analogous to normal Text_IO procs of same name.
      --  The text is put in Buffer, then it will be written into a temporary
      --  file with procedure Write_Temp_File below.

      procedure Write_Temp_File;
      --  Create a temporary file and put the content of the buffer in it

      -----------
      -- Check --
      -----------

      procedure Check
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         State   : in out Integer)
      is
         pragma Unreferenced (State);

         Lang   : constant Language_Ptr :=
                    Get_Language_From_Name (Project, "ada");
         Naming : Lang_Naming_Data;
         Iter   : Source_Iterator;
         Source : Source_Id;

      begin
         if Current_Verbosity = High then
            Debug_Output ("Checking project file:", Project.Name);
         end if;

         if Lang = null then
            if Current_Verbosity = High then
               Debug_Output ("Languages does not contain Ada, nothing to do");
            end if;

            return;
         end if;

         --  Visit all the files and process those that need an SFN pragma

         Iter := For_Each_Source (In_Tree, Project);
         while Element (Iter) /= No_Source loop
            Source := Element (Iter);

            if not Source.Locally_Removed
              and then Source.Unit /= null
              and then
                (Source.Index >= 1 or else Source.Naming_Exception /= No)
            then
               Put (Source);
            end if;

            Next (Iter);
         end loop;

         Naming := Lang.Config.Naming_Data;

         --  Is the naming scheme of this project one that we know?

         Current_Naming := Default_Naming;
         while Current_Naming <= Naming_Table.Last (Namings)
           and then Namings.Table (Current_Naming).Dot_Replacement =
                                                    Naming.Dot_Replacement
           and then Namings.Table (Current_Naming).Casing =
                                                    Naming.Casing
           and then Namings.Table (Current_Naming).Separate_Suffix =
                                                    Naming.Separate_Suffix
         loop
            Current_Naming := Current_Naming + 1;
         end loop;

         --  If we don't know it, add it

         if Current_Naming > Naming_Table.Last (Namings) then
            Naming_Table.Increment_Last (Namings);
            Namings.Table (Naming_Table.Last (Namings)) := Naming;

            --  Put the SFN pragmas for the naming scheme

            --  Spec

            Put_Line
              ("pragma Source_File_Name_Project");
            Put_Line
              ("  (Spec_File_Name  => ""*" &
               Get_Name_String (Naming.Spec_Suffix) & """,");
            Put_Line
              ("   Casing          => " &
               Image (Naming.Casing) & ",");
            Put_Line
              ("   Dot_Replacement => """ &
               Get_Name_String (Naming.Dot_Replacement) & """);");

            --  and body

            Put_Line
              ("pragma Source_File_Name_Project");
            Put_Line
              ("  (Body_File_Name  => ""*" &
               Get_Name_String (Naming.Body_Suffix) & """,");
            Put_Line
              ("   Casing          => " &
               Image (Naming.Casing) & ",");
            Put_Line
              ("   Dot_Replacement => """ &
               Get_Name_String (Naming.Dot_Replacement) &
               """);");

            --  and maybe separate

            if Naming.Body_Suffix /= Naming.Separate_Suffix then
               Put_Line ("pragma Source_File_Name_Project");
               Put_Line
                 ("  (Subunit_File_Name  => ""*" &
                  Get_Name_String (Naming.Separate_Suffix) & """,");
               Put_Line
                 ("   Casing          => " &
                  Image (Naming.Casing) & ",");
               Put_Line
                 ("   Dot_Replacement => """ &
                  Get_Name_String (Naming.Dot_Replacement) &
                  """);");
            end if;
         end if;
      end Check;

      ---------
      -- Put --
      ---------

      procedure Put (Source : Source_Id) is
      begin
         --  Put the pragma SFN for the unit kind (spec or body)

         Put ("pragma Source_File_Name_Project (");
         Put (Get_Name_String (Source.Unit.Name));

         if Source.Kind = Spec then
            Put (", Spec_File_Name => """);
         else
            Put (", Body_File_Name => """);
         end if;

         Put (Get_Name_String (Source.File));
         Put ("""");

         if Source.Index /= 0 then
            Put (", Index =>");
            Put (Source.Index'Img);
         end if;

         Put_Line (");");
      end Put;

      procedure Put (S : String) is
      begin
         Add_To_Buffer (S, Buffer, Buffer_Last);

         if Current_Verbosity = High then
            Write_Str (S);
         end if;
      end Put;

      --------------
      -- Put_Line --
      --------------

      procedure Put_Line (S : String) is
      begin
         --  Add an ASCII.LF to the string. As this config file is supposed to
         --  be used only by the compiler, we don't care about the characters
         --  for the end of line. In fact we could have put a space, but
         --  it is more convenient to be able to read gnat.adc during
         --  development, for which the ASCII.LF is fine.

         Put (S);
         Put (S => (1 => ASCII.LF));
      end Put_Line;

      ---------------------
      -- Write_Temp_File --
      ---------------------

      procedure Write_Temp_File is
         Status : Boolean := False;
         Last   : Natural;

      begin
         Create_Temp_File (In_Tree.Shared, File, File_Name, "config pragmas");

         if File /= Invalid_FD then
            Last := Write (File, Buffer (1)'Address, Buffer_Last);

            if Last = Buffer_Last then
               Close (File, Status);
            end if;
         end if;

         if not Status then
            GPR.Com.Fail ("unable to create temporary file");
         end if;
      end Write_Temp_File;

      procedure Check_Imported_Projects is
        new For_Every_Project_Imported (Integer, Check);

      Dummy : Integer := 0;

   --  Start of processing for Create_Config_Pragmas_File

      use Opt;

   begin
      if not For_Project.Config_Checked then
         Naming_Table.Init (Namings);

         --  Check the naming schemes

         Check_Imported_Projects
           (For_Project, In_Tree, Dummy, Imported_First => False);

         --  If there are no non standard naming scheme, issue the GNAT
         --  standard naming scheme. This will tell the compiler that
         --  a project file is used and will forbid any pragma SFN.

         if Buffer_Last = 0 then

            Put_Line ("pragma Source_File_Name_Project");
            Put_Line ("   (Spec_File_Name  => ""*.ads"",");
            Put_Line ("    Dot_Replacement => ""-"",");
            Put_Line ("    Casing          => lowercase);");

            Put_Line ("pragma Source_File_Name_Project");
            Put_Line ("   (Body_File_Name  => ""*.adb"",");
            Put_Line ("    Dot_Replacement => ""-"",");
            Put_Line ("    Casing          => lowercase);");
         end if;

         --  Close the temporary file

         Write_Temp_File;

         if Opt.Verbosity_Level > Opt.Low then
            Write_Str ("Created configuration file """);
            Write_Str (Get_Name_String (File_Name));
            Write_Line ("""");
         end if;

         For_Project.Config_File_Name := File_Name;
         For_Project.Config_File_Temp := True;
         For_Project.Config_Checked   := True;
      end if;

      Free (Buffer);
   end Create_Config_Pragmas_File;

   -------------------------
   -- Create_Mapping_File --
   -------------------------

   package Mapping is new GNAT.HTable.Simple_HTable
     (Header_Num => Header_Num,
      Element     => Source_Id,
      No_Element  => No_Source,
      Key         => Name_Id,
      Hash        => Hash,
      Equal       => "=");
   --  A table to store the non excluded sources

   type Source_Unit is record
      Source : Source_Id := No_Source;
      Unit   : Name_Id   := No_Name;
   end record;

   No_Source_Unit : constant Source_Unit := (No_Source, No_Name);

   package Mapping_Excluded_Paths is new GNAT.HTable.Simple_HTable
     (Header_Num => Header_Num,
      Element     => Source_Unit,
      No_Element  => No_Source_Unit,
      Key         => Path_Name_Type,
      Hash        => Hash,
      Equal       => "=");
   --  A table to store the excluded sources

   procedure Create_Mapping_File
     (Project  : Project_Id;
      Language : Name_Id;
      In_Tree  : Project_Tree_Ref;
      Name     : out Path_Name_Type)
   is
      File        : File_Descriptor := Invalid_FD;
      Buffer      : String_Access   := new String (1 .. Buffer_Initial);
      Buffer_Last : Natural         := 0;

      procedure Put_Name_Buffer;
      --  Put the line contained in the Name_Buffer in the global buffer

      procedure Process
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         State   : in out Integer);
      --  Generate the mapping file for Project (not recursively)

      ---------------------
      -- Put_Name_Buffer --
      ---------------------

      procedure Put_Name_Buffer is
      begin
         if Current_Verbosity = High then
            Debug_Output (Name_Buffer (1 .. Name_Len));
         end if;

         Name_Len := Name_Len + 1;
         Name_Buffer (Name_Len) := ASCII.LF;
         Add_To_Buffer (Name_Buffer (1 .. Name_Len), Buffer, Buffer_Last);
      end Put_Name_Buffer;

      -------------
      -- Process --
      -------------

      procedure Process
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         State   : in out Integer)
      is
         pragma Unreferenced (State);

         Source : Source_Id;
         Iter   : Source_Iterator;

         Unit : Name_Id;

      begin
         Debug_Output ("Add mapping for project", Project.Name);
         Iter := For_Each_Source (In_Tree, Project, Language => Language);

         loop
            Source := GPR.Element (Iter);
            exit when Source = No_Source;

            if Source.Replaced_By = No_Source
              and then Source.Path.Name /= No_Path
              and then Source.Unit /= No_Unit_Index
            then

               --  Get the encoded unit name in the name buffer

               declare
                  Uname : constant String :=
                    Get_Name_String (Source.Unit.Name);

               begin
                  Name_Len := 0;
                  for J in Uname'Range loop
                     if Uname (J) in Upper_Half_Character then
                        Store_Encoded_Character (Get_Char_Code (Uname (J)));
                     else
                        Add_Char_To_Name_Buffer (Uname (J));
                     end if;
                  end loop;
               end;

               Add_Char_To_Name_Buffer ('%');

               if Source.Kind = Spec then
                  Add_Char_To_Name_Buffer ('s');
               else
                  Add_Char_To_Name_Buffer ('b');
               end if;

               Unit := Name_Find;

               declare
                  Src : constant Source_Id := Mapping.Get (Unit);
               begin
                  if Src = No_Source or else
                    not (Source.Locally_Removed or else Source.Suppressed)
                  then
                     if Source.Locally_Removed or else Source.Suppressed then
                        if Src = No_Source then
                           Mapping_Excluded_Paths.Set
                             (Source.Path.Name, (Source, Unit));
                        end if;

                     else
                        Mapping.Set (Unit, Source);

                        --  Remove any excluded source with the same path, if
                        --  any.
                        Mapping_Excluded_Paths.Remove (Source.Path.Name);

                        --  Also remove any excluded source with the same unit
                        --  name.

                        declare
                           Src_Unit : Source_Unit := No_Source_Unit;
                           Path     : Path_Name_Type := No_Path;
                        begin
                           Mapping_Excluded_Paths.Get_First (Path, Src_Unit);
                           while Src_Unit /= No_Source_Unit loop
                              if Src_Unit.Unit = Unit then
                                 Mapping_Excluded_Paths.Remove (Path);
                                 exit;
                              end if;

                              Mapping_Excluded_Paths.Get_Next (Path, Src_Unit);
                           end loop;
                        end;
                     end if;
                  end if;
               end;
            end if;

            Next (Iter);
         end loop;
      end Process;

      procedure For_Every_Imported_Project is new
        For_Every_Project_Imported (State => Integer, Action => Process);

      --  Local variables

      Dummy : Integer := 0;

   --  Start of processing for Create_Mapping_File

   begin
      if Current_Verbosity = High then
         Debug_Output ("Create mapping file for", Debug_Name (In_Tree));
      end if;

      Create_Temp_File (In_Tree.Shared, File, Name, "mapping");

      if Current_Verbosity = High then
         Debug_Increase_Indent ("Create mapping file ", Name_Id (Name));
      end if;

      Mapping.Reset;
      Mapping_Excluded_Paths.Reset;

      For_Every_Imported_Project
        (Project, In_Tree, Dummy, Include_Aggregated => False);

      declare
         Last     : Natural;
         Status   : Boolean        := False;
         Unit     : Name_Id        := No_Name;
         Source   : Source_Id;
         Path     : Path_Name_Type := No_Path;
         Src_Unit : Source_Unit;

      begin
         if File /= Invalid_FD then

            --  First the non excluded sources

            Mapping.Get_First (Unit, Source);
            while Source /= No_Source loop
               Get_Name_String (Unit);
               Put_Name_Buffer;

               Get_Name_String (Source.Display_File);
               Put_Name_Buffer;

               Get_Name_String (Source.Path.Display_Name);
               Put_Name_Buffer;

               Mapping.Get_Next (Unit, Source);
            end loop;

            --  Then the excluded sources, if any

            Mapping_Excluded_Paths.Get_First (Path, Src_Unit);
            while Src_Unit /= No_Source_Unit loop
               Get_Name_String (Src_Unit.Unit);
               Put_Name_Buffer;

               Get_Name_String (Src_Unit.Source.Display_File);
               Put_Name_Buffer;

               Name_Len := 1;
               Name_Buffer (1) := '/';
               Put_Name_Buffer;

               Mapping_Excluded_Paths.Get_Next (Path, Src_Unit);
            end loop;

            Last := Write (File, Buffer (1)'Address, Buffer_Last);

            if Last = Buffer_Last then
               GNAT.OS_Lib.Close (File, Status);
            end if;
         end if;

         if not Status then
            GPR.Com.Fail ("could not write mapping file");
         end if;
      end;

      Free (Buffer);

      Debug_Decrease_Indent ("Done create mapping file");
   end Create_Mapping_File;

   ----------------------
   -- Create_Temp_File --
   ----------------------

   procedure Create_Temp_File
     (Shared    : Shared_Project_Tree_Data_Access;
      Path_FD   : out File_Descriptor;
      Path_Name : out Path_Name_Type;
      File_Use  : String)
   is
   begin
      Tempdir.Create_Temp_File (Path_FD, Path_Name);

      if Path_Name /= No_Path then
         if Current_Verbosity = High then
            Write_Line ("Create temp file (" & File_Use & ") "
                        & Get_Name_String (Path_Name));
         end if;

         Record_Temp_File (Shared, Path_Name);

      else
         GPR.Com.Fail
           ("unable to create temporary " & File_Use & " file");
      end if;
   end Create_Temp_File;

   --------------------------
   -- Create_New_Path_File --
   --------------------------

   procedure Create_New_Path_File
     (Shared    : Shared_Project_Tree_Data_Access;
      Path_FD   : out File_Descriptor;
      Path_Name : out Path_Name_Type)
   is
   begin
      Create_Temp_File (Shared, Path_FD, Path_Name, "path file");
   end Create_New_Path_File;

   ------------------------------------
   -- File_Name_Of_Library_Unit_Body --
   ------------------------------------

   function File_Name_Of_Library_Unit_Body
     (Name              : String;
      Project           : Project_Id;
      In_Tree           : Project_Tree_Ref;
      Main_Project_Only : Boolean := True;
      Full_Path         : Boolean := False) return String
   is

      Lang          : constant Language_Ptr :=
                        Get_Language_From_Name (Project, "ada");
      The_Project   : Project_Id := Project;
      Original_Name : String := Name;

      Unit              : Unit_Index;
      The_Original_Name : Name_Id;
      The_Spec_Name     : Name_Id;
      The_Body_Name     : Name_Id;

   begin
      --  ??? Same block in Project_Of
      Canonical_Case_File_Name (Original_Name);
      Name_Len := Original_Name'Length;
      Name_Buffer (1 .. Name_Len) := Original_Name;
      The_Original_Name := Name_Find;

      if Lang /= null then
         declare
            Naming : constant Lang_Naming_Data := Lang.Config.Naming_Data;
            Extended_Spec_Name : String :=
                                   Name & Get_Name_String
                                            (Naming.Spec_Suffix);
            Extended_Body_Name : String :=
                                   Name & Get_Name_String
                                            (Naming.Body_Suffix);

         begin
            Canonical_Case_File_Name (Extended_Spec_Name);
            Name_Len := Extended_Spec_Name'Length;
            Name_Buffer (1 .. Name_Len) := Extended_Spec_Name;
            The_Spec_Name := Name_Find;

            Canonical_Case_File_Name (Extended_Body_Name);
            Name_Len := Extended_Body_Name'Length;
            Name_Buffer (1 .. Name_Len) := Extended_Body_Name;
            The_Body_Name := Name_Find;
         end;

      else
         Name_Len := Name'Length;
         Name_Buffer (1 .. Name_Len) := Name;
         Canonical_Case_File_Name (Name_Buffer);
         The_Spec_Name := Name_Find;
         The_Body_Name := The_Spec_Name;
      end if;

      if Current_Verbosity = High then
         Write_Str  ("Looking for file name of """);
         Write_Str  (Name);
         Write_Char ('"');
         Write_Eol;
         Write_Str  ("   Extended Spec Name = """);
         Write_Str  (Get_Name_String (The_Spec_Name));
         Write_Char ('"');
         Write_Eol;
         Write_Str ("   Extended Body Name = """);
         Write_Str (Get_Name_String (The_Body_Name));
         Write_Char ('"');
         Write_Eol;
      end if;

      --  For extending project, search in the extended project if the source
      --  is not found. For non extending projects, this loop will be run only
      --  once.

      loop
         --  Loop through units

         Unit := Units_Htable.Get_First (In_Tree.Units_HT);
         while Unit /= null loop

            --  Check for body

            if not Main_Project_Only
              or else
                (Unit.File_Names (Impl) /= null
                  and then Unit.File_Names (Impl).Project = The_Project)
            then
               declare
                  Current_Name : File_Name_Type;

               begin
                  --  Case of a body present

                  if Unit.File_Names (Impl) /= null then
                     Current_Name := Unit.File_Names (Impl).File;

                     if Current_Verbosity = High then
                        Write_Str  ("   Comparing with """);
                        Write_Str  (Get_Name_String (Current_Name));
                        Write_Char ('"');
                        Write_Eol;
                     end if;

                     --  If it has the name of the original name, return the
                     --  original name.

                     if Unit.Name = The_Original_Name
                       or else
                         Current_Name = File_Name_Type (The_Original_Name)
                     then
                        if Current_Verbosity = High then
                           Write_Line ("   OK");
                        end if;

                        if Full_Path then
                           return Get_Name_String
                             (Unit.File_Names (Impl).Path.Name);

                        else
                           return Get_Name_String (Current_Name);
                        end if;

                        --  If it has the name of the extended body name,
                        --  return the extended body name

                     elsif Current_Name = File_Name_Type (The_Body_Name) then
                        if Current_Verbosity = High then
                           Write_Line ("   OK");
                        end if;

                        if Full_Path then
                           return Get_Name_String
                             (Unit.File_Names (Impl).Path.Name);

                        else
                           return Get_Name_String (The_Body_Name);
                        end if;

                     else
                        if Current_Verbosity = High then
                           Put_Line ("   not good");
                        end if;
                     end if;
                  end if;
               end;
            end if;

            --  Check for spec

            if not Main_Project_Only
              or else (Unit.File_Names (Spec) /= null
                        and then Unit.File_Names (Spec).Project = The_Project)
            then
               declare
                  Current_Name : File_Name_Type;

               begin
                  --  Case of spec present

                  if Unit.File_Names (Spec) /= null then
                     Current_Name := Unit.File_Names (Spec).File;
                     if Current_Verbosity = High then
                        Write_Str  ("   Comparing with """);
                        Write_Str  (Get_Name_String (Current_Name));
                        Write_Char ('"');
                        Write_Eol;
                     end if;

                     --  If name same as original name, return original name

                     if Unit.Name = The_Original_Name
                       or else
                         Current_Name = File_Name_Type (The_Original_Name)
                     then
                        if Current_Verbosity = High then
                           Write_Line ("   OK");
                        end if;

                        if Full_Path then
                           return Get_Name_String
                             (Unit.File_Names (Spec).Path.Name);
                        else
                           return Get_Name_String (Current_Name);
                        end if;

                        --  If it has the same name as the extended spec name,
                        --  return the extended spec name.

                     elsif Current_Name = File_Name_Type (The_Spec_Name) then
                        if Current_Verbosity = High then
                           Write_Line ("   OK");
                        end if;

                        if Full_Path then
                           return Get_Name_String
                             (Unit.File_Names (Spec).Path.Name);
                        else
                           return Get_Name_String (The_Spec_Name);
                        end if;

                     else
                        if Current_Verbosity = High then
                           Write_Line ("   not good");
                        end if;
                     end if;
                  end if;
               end;
            end if;

            Unit := Units_Htable.Get_Next (In_Tree.Units_HT);
         end loop;

         --  If we are not in an extending project, give up

         exit when not Main_Project_Only
           or else The_Project.Extends = No_Project;

         --  Otherwise, look in the project we are extending

         The_Project := The_Project.Extends;
      end loop;

      --  We don't know this file name, return an empty string

      return "";
   end File_Name_Of_Library_Unit_Body;

   -------------------------
   -- For_All_Object_Dirs --
   -------------------------

   procedure For_All_Object_Dirs
     (Project : Project_Id;
      Tree    : Project_Tree_Ref)
   is
      procedure For_Project
        (Prj   : Project_Id;
         Tree  : Project_Tree_Ref;
         Dummy : in out Integer);
      --  Get all object directories of Prj

      -----------------
      -- For_Project --
      -----------------

      procedure For_Project
        (Prj   : Project_Id;
         Tree  : Project_Tree_Ref;
         Dummy : in out Integer)
      is
         pragma Unreferenced (Tree);

      begin
         --  ??? Set_Ada_Paths has a different behavior for library project
         --  files, should we have the same ?

         if Prj.Object_Directory /= No_Path_Information then
            Get_Name_String (Prj.Object_Directory.Display_Name);
            Action (Name_Buffer (1 .. Name_Len));
         end if;
      end For_Project;

      procedure Get_Object_Dirs is
        new For_Every_Project_Imported (Integer, For_Project);
      Dummy : Integer := 1;

   --  Start of processing for For_All_Object_Dirs

   begin
      Get_Object_Dirs (Project, Tree, Dummy);
   end For_All_Object_Dirs;

   -------------------------
   -- For_All_Source_Dirs --
   -------------------------

   procedure For_All_Source_Dirs
     (Project : Project_Id;
      In_Tree : Project_Tree_Ref)
   is
      procedure For_Project
        (Prj     : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Integer);
      --  Get all object directories of Prj

      -----------------
      -- For_Project --
      -----------------

      procedure For_Project
        (Prj     : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Integer)
      is
         Current    : String_List_Id := Prj.Source_Dirs;
         The_String : String_Element;

      begin
         --  If there are Ada sources, call action with the name of every
         --  source directory.

         if Has_Ada_Sources (Prj) then
            while Current /= Nil_String loop
               The_String := In_Tree.Shared.String_Elements.Table (Current);
               Action (Get_Name_String (The_String.Display_Value));
               Current := The_String.Next;
            end loop;
         end if;
      end For_Project;

      procedure Get_Source_Dirs is
        new For_Every_Project_Imported (Integer, For_Project);
      Dummy : Integer := 1;

   --  Start of processing for For_All_Source_Dirs

   begin
      Get_Source_Dirs (Project, In_Tree, Dummy);
   end For_All_Source_Dirs;

   -------------------
   -- Get_Reference --
   -------------------

   procedure Get_Reference
     (Source_File_Name : String;
      In_Tree          : Project_Tree_Ref;
      Project          : out Project_Id;
      Path             : out Path_Name_Type)
   is
   begin
      --  Body below could use some comments ???

      if Current_Verbosity > Default then
         Write_Str ("Getting Reference_Of (""");
         Write_Str (Source_File_Name);
         Write_Str (""") ... ");
      end if;

      declare
         Original_Name : String := Source_File_Name;
         Unit          : Unit_Index;

      begin
         Canonical_Case_File_Name (Original_Name);
         Unit := Units_Htable.Get_First (In_Tree.Units_HT);

         while Unit /= null loop
            if Unit.File_Names (Spec) /= null
              and then not Unit.File_Names (Spec).Locally_Removed
              and then Unit.File_Names (Spec).File /= No_File
              and then
                (Get_Name_String
                   (Unit.File_Names (Spec).File) = Original_Name
                 or else (Unit.File_Names (Spec).Path /= No_Path_Information
                           and then
                             Get_Name_String
                               (Unit.File_Names (Spec).Path.Name) =
                                                           Original_Name))
            then
               Project :=
                 Ultimate_Extending_Project_Of
                   (Unit.File_Names (Spec).Project);
               Path := Unit.File_Names (Spec).Path.Display_Name;

               if Current_Verbosity > Default then
                  Write_Str ("Done: Spec.");
                  Write_Eol;
               end if;

               return;

            elsif Unit.File_Names (Impl) /= null
              and then Unit.File_Names (Impl).File /= No_File
              and then not Unit.File_Names (Impl).Locally_Removed
              and then
                (Get_Name_String
                   (Unit.File_Names (Impl).File) = Original_Name
                  or else (Unit.File_Names (Impl).Path /= No_Path_Information
                            and then Get_Name_String
                                       (Unit.File_Names (Impl).Path.Name) =
                                                              Original_Name))
            then
               Project :=
                 Ultimate_Extending_Project_Of
                   (Unit.File_Names (Impl).Project);
               Path := Unit.File_Names (Impl).Path.Display_Name;

               if Current_Verbosity > Default then
                  Write_Str ("Done: Body.");
                  Write_Eol;
               end if;

               return;
            end if;

            Unit := Units_Htable.Get_Next (In_Tree.Units_HT);
         end loop;
      end;

      Project := No_Project;
      Path    := No_Path;

      if Current_Verbosity > Default then
         Write_Str ("Cannot be found.");
         Write_Eol;
      end if;
   end Get_Reference;

   ----------------------
   -- Get_Runtime_Path --
   ----------------------

   function Get_Runtime_Path
     (Self : in out Project_Search_Path;
      Name : String) return String_Access
   is
      function Find_Rts_In_Path is
        new GPR.Env.Find_Name_In_Path (Check_Filename => Is_Directory);
   begin
      return Find_Rts_In_Path (Self, Name);
   end Get_Runtime_Path;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize (In_Tree : Project_Tree_Ref) is
   begin
      In_Tree.Shared.Private_Part.Current_Source_Path_File := No_Path;
      In_Tree.Shared.Private_Part.Current_Object_Path_File := No_Path;
   end Initialize;

   -------------------
   -- Print_Sources --
   -------------------

   --  Could use some comments in this body ???

   procedure Print_Sources (In_Tree : Project_Tree_Ref) is
      Unit : Unit_Index;

   begin
      Write_Line ("List of Sources:");

      Unit := Units_Htable.Get_First (In_Tree.Units_HT);
      while Unit /= No_Unit_Index loop
         Write_Str  ("   ");
         Write_Line (Get_Name_String (Unit.Name));

         if Unit.File_Names (Spec).File /= No_File then
            if Unit.File_Names (Spec).Project = No_Project then
               Write_Line ("   No project");

            else
               Write_Str ("   Project: ");
               Get_Name_String
                 (Unit.File_Names (Spec).Project.Path.Name);
               Write_Line (Name_Buffer (1 .. Name_Len));
            end if;

            Write_Str ("      spec: ");
            Write_Line (Get_Name_String (Unit.File_Names (Spec).File));
         end if;

         if Unit.File_Names (Impl).File /= No_File then
            if Unit.File_Names (Impl).Project = No_Project then
               Write_Line ("   No project");

            else
               Write_Str ("   Project: ");
               Get_Name_String
                 (Unit.File_Names (Impl).Project.Path.Name);
               Write_Line (Name_Buffer (1 .. Name_Len));
            end if;

            Write_Str  ("      body: ");
            Write_Line (Get_Name_String (Unit.File_Names (Impl).File));
         end if;

         Unit := Units_Htable.Get_Next (In_Tree.Units_HT);
      end loop;

      Write_Line ("end of List of Sources.");
   end Print_Sources;

   ----------------
   -- Project_Of --
   ----------------

   function Project_Of
     (Name         : String;
      Main_Project : Project_Id;
      In_Tree      : Project_Tree_Ref) return Project_Id
   is
      Result : Project_Id := No_Project;

      Original_Name : String := Name;

      Lang : constant Language_Ptr :=
               Get_Language_From_Name (Main_Project, "ada");

      Unit : Unit_Index;

      Current_Name      : File_Name_Type;
      The_Original_Name : File_Name_Type;
      The_Spec_Name     : File_Name_Type;
      The_Body_Name     : File_Name_Type;

   begin
      --  ??? Same block in File_Name_Of_Library_Unit_Body
      Canonical_Case_File_Name (Original_Name);
      Name_Len := Original_Name'Length;
      Name_Buffer (1 .. Name_Len) := Original_Name;
      The_Original_Name := Name_Find;

      if Lang /= null then
         declare
            Naming : Lang_Naming_Data renames Lang.Config.Naming_Data;
            Extended_Spec_Name : String :=
                                   Name & Get_Name_String
                                            (Naming.Spec_Suffix);
            Extended_Body_Name : String :=
                                   Name & Get_Name_String
                                            (Naming.Body_Suffix);

         begin
            Canonical_Case_File_Name (Extended_Spec_Name);
            Name_Len := Extended_Spec_Name'Length;
            Name_Buffer (1 .. Name_Len) := Extended_Spec_Name;
            The_Spec_Name := Name_Find;

            Canonical_Case_File_Name (Extended_Body_Name);
            Name_Len := Extended_Body_Name'Length;
            Name_Buffer (1 .. Name_Len) := Extended_Body_Name;
            The_Body_Name := Name_Find;
         end;

      else
         The_Spec_Name := The_Original_Name;
         The_Body_Name := The_Original_Name;
      end if;

      Unit := Units_Htable.Get_First (In_Tree.Units_HT);
      while Unit /= null loop

         --  Case of a body present

         if Unit.File_Names (Impl) /= null then
            Current_Name := Unit.File_Names (Impl).File;

            --  If it has the name of the original name or the body name,
            --  we have found the project.

            if Unit.Name = Name_Id (The_Original_Name)
              or else Current_Name = The_Original_Name
              or else Current_Name = The_Body_Name
            then
               Result := Unit.File_Names (Impl).Project;
               exit;
            end if;
         end if;

         --  Check for spec

         if Unit.File_Names (Spec) /= null then
            Current_Name := Unit.File_Names (Spec).File;

            --  If name same as the original name, or the spec name, we have
            --  found the project.

            if Unit.Name = Name_Id (The_Original_Name)
              or else Current_Name = The_Original_Name
              or else Current_Name = The_Spec_Name
            then
               Result := Unit.File_Names (Spec).Project;
               exit;
            end if;
         end if;

         Unit := Units_Htable.Get_Next (In_Tree.Units_HT);
      end loop;

      return Ultimate_Extending_Project_Of (Result);
   end Project_Of;

   -------------------
   -- Set_Ada_Paths --
   -------------------

   procedure Set_Ada_Paths
     (Project             : Project_Id;
      In_Tree             : Project_Tree_Ref;
      Including_Libraries : Boolean;
      Include_Path        : Boolean := True;
      Objects_Path        : Boolean := True)

   is
      Shared : constant Shared_Project_Tree_Data_Access := In_Tree.Shared;

      Source_Paths : Source_Path_Table.Instance;
      Object_Paths : Object_Path_Table.Instance;
      --  List of source or object dirs. Only computed the first time this
      --  procedure is called (since Source_FD is then reused)

      Source_FD : File_Descriptor := Invalid_FD;
      Object_FD : File_Descriptor := Invalid_FD;
      --  The temporary files to store the paths. These are only created the
      --  first time this procedure is called, and reused from then on.

      Process_Source_Dirs : Boolean := False;
      Process_Object_Dirs : Boolean := False;

      Status : Boolean;
      --  For calls to Close

      Last        : Natural;
      Buffer      : String_Access := new String (1 .. Buffer_Initial);
      Buffer_Last : Natural := 0;

      procedure Recursive_Add
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Boolean);
      --  Recursive procedure to add the source/object paths of extended/
      --  imported projects.

      -------------------
      -- Recursive_Add --
      -------------------

      procedure Recursive_Add
        (Project : Project_Id;
         In_Tree : Project_Tree_Ref;
         Dummy   : in out Boolean)
      is
         pragma Unreferenced (In_Tree);

         Path : Path_Name_Type;

      begin
         if Process_Source_Dirs then

            --  Add to path all source directories of this project if there are
            --  Ada sources.

            if Has_Ada_Sources (Project) then
               Add_To_Source_Path (Project.Source_Dirs, Shared, Source_Paths);
            end if;
         end if;

         if Process_Object_Dirs then
            Path := Get_Object_Directory
              (Project,
               Including_Libraries => Including_Libraries,
               Only_If_Ada         => True);

            if Path /= No_Path then
               Add_To_Object_Path (Path, Object_Paths);
            end if;
         end if;
      end Recursive_Add;

      procedure For_All_Projects is
        new For_Every_Project_Imported (Boolean, Recursive_Add);

      Dummy : Boolean := False;

   --  Start of processing for Set_Ada_Paths

   begin
      --  If it is the first time we call this procedure for this project,
      --  compute the source path and/or the object path.

      if Include_Path and then Project.Include_Path_File = No_Path then
         Source_Path_Table.Init (Source_Paths);
         Process_Source_Dirs := True;
         Create_New_Path_File (Shared, Source_FD, Project.Include_Path_File);
      end if;

      --  For the object path, we make a distinction depending on
      --  Including_Libraries.

      if Objects_Path and then Including_Libraries then
         if Project.Objects_Path_File_With_Libs = No_Path then
            Object_Path_Table.Init (Object_Paths);
            Process_Object_Dirs := True;
            Create_New_Path_File
              (Shared, Object_FD, Project.Objects_Path_File_With_Libs);
         end if;

      elsif Objects_Path then
         if Project.Objects_Path_File_Without_Libs = No_Path then
            Object_Path_Table.Init (Object_Paths);
            Process_Object_Dirs := True;
            Create_New_Path_File
              (Shared, Object_FD, Project.Objects_Path_File_Without_Libs);
         end if;
      end if;

      --  If there is something to do, set Seen to False for all projects,
      --  then call the recursive procedure Add for Project.

      if Process_Source_Dirs or else Process_Object_Dirs then
         For_All_Projects (Project, In_Tree, Dummy);
      end if;

      --  Write and close any file that has been created. Source_FD is not set
      --  when this subprogram is called a second time or more, since we reuse
      --  the previous version of the file.

      if Source_FD /= Invalid_FD then
         Buffer_Last := 0;

         for Index in
           Source_Path_Table.First .. Source_Path_Table.Last (Source_Paths)
         loop
            Get_Name_String (Source_Paths.Table (Index));
            Name_Len := Name_Len + 1;
            Name_Buffer (Name_Len) := ASCII.LF;
            Add_To_Buffer (Name_Buffer (1 .. Name_Len), Buffer, Buffer_Last);
         end loop;

         Last := Write (Source_FD, Buffer (1)'Address, Buffer_Last);

         if Last = Buffer_Last then
            Close (Source_FD, Status);

         else
            Status := False;
         end if;

         if not Status then
            GPR.Com.Fail ("could not write temporary file");
         end if;
      end if;

      if Object_FD /= Invalid_FD then
         Buffer_Last := 0;

         for Index in
           Object_Path_Table.First .. Object_Path_Table.Last (Object_Paths)
         loop
            Get_Name_String (Object_Paths.Table (Index));
            Name_Len := Name_Len + 1;
            Name_Buffer (Name_Len) := ASCII.LF;
            Add_To_Buffer (Name_Buffer (1 .. Name_Len), Buffer, Buffer_Last);
         end loop;

         Last := Write (Object_FD, Buffer (1)'Address, Buffer_Last);

         if Last = Buffer_Last then
            Close (Object_FD, Status);
         else
            Status := False;
         end if;

         if not Status then
            GPR.Com.Fail ("could not write temporary file");
         end if;
      end if;

      --  Set the env vars, if they need to be changed, and set the
      --  corresponding flags.

      if Include_Path
        and then
          Shared.Private_Part.Current_Source_Path_File /=
            Project.Include_Path_File
      then
         Shared.Private_Part.Current_Source_Path_File :=
           Project.Include_Path_File;
         Set_Path_File_Var
           (Project_Include_Path_File,
            Get_Name_String (Shared.Private_Part.Current_Source_Path_File));
      end if;

      if Objects_Path then
         if Including_Libraries then
            if Shared.Private_Part.Current_Object_Path_File /=
              Project.Objects_Path_File_With_Libs
            then
               Shared.Private_Part.Current_Object_Path_File :=
                 Project.Objects_Path_File_With_Libs;
               Set_Path_File_Var
                 (Project_Objects_Path_File,
                  Get_Name_String
                    (Shared.Private_Part.Current_Object_Path_File));
            end if;

         else
            if Shared.Private_Part.Current_Object_Path_File /=
              Project.Objects_Path_File_Without_Libs
            then
               Shared.Private_Part.Current_Object_Path_File :=
                 Project.Objects_Path_File_Without_Libs;
               Set_Path_File_Var
                 (Project_Objects_Path_File,
                  Get_Name_String
                    (Shared.Private_Part.Current_Object_Path_File));
            end if;
         end if;
      end if;

      Free (Buffer);
   end Set_Ada_Paths;

   ---------------
   -- To_Vector --
   ---------------

   function To_Vector (Path : String) return Util.String_Vectors.Vector is
      use GNAT.String_Split;
      Result : Util.String_Vectors.Vector;
   begin
      for P of Create (Path, (1 => Path_Separator), Mode => Multiple) loop
         Result.Append (P);
      end loop;

      return Result;
   end To_Vector;

   ---------------------
   -- Add_Directories --
   ---------------------

   procedure Add_Directories
     (Self    : in out Project_Search_Path;
      Path    : String;
      Prepend : Boolean := False) is
   begin
      if Prepend then
         Self.Path.Prepend_Vector (To_Vector (Path));
      else
         Self.Path.Append_Vector (To_Vector (Path));
      end if;

      if Current_Verbosity = High then
         Debug_Output ("Adding directories to Project_Path: """
                       & Path & '"');
      end if;
   end Add_Directories;

   ----------------------
   -- Initialize_Empty --
   ----------------------

   procedure Initialize_Empty (Self : in out Project_Search_Path) is
   begin
      Self.Path.Clear;
      Self.Initialized := True;
   end Initialize_Empty;

   -------------------------------------
   -- Initialize_Default_Project_Path --
   -------------------------------------

   procedure Initialize_Default_Project_Path
     (Self         : in out Project_Search_Path;
      Target_Name  : String;
      Runtime_Name : String := "")
   is
      Add_Default_Dir : Boolean := Target_Name /= "-";
      Index           : Positive;

      Ada_Project_Path      : constant String := "ADA_PROJECT_PATH";
      Gpr_Project_Path      : constant String := "GPR_PROJECT_PATH";
      Gpr_Project_Path_File : constant String := "GPR_PROJECT_PATH_FILE";
      --  Names of alternate env. variable that contain path name(s) of
      --  directories where project files may reside. They are taken into
      --  account in this order: GPR_PROJECT_PATH_FILE, GPR_PROJECT_PATH,
      --  ADA_PROJECT_PATH.

      Gpr_Prj_Path_File : String_Access;
      Gpr_Prj_Path      : String_Access;
      Ada_Prj_Path      : String_Access;
      --  The path name(s) of directories where project files may reside.
      --  May be empty.

   --  Start of processing for Initialize_Default_Project_Path

   begin
      if Is_Initialized (Self) then
         return;
      end if;

      --  The current directory is always first in the search path. Since the
      --  Project_Path currently starts with '#:' as a sign that it isn't
      --  initialized, we simply replace '#' with '.'

      Self.Path.Prepend (".");
      Self.Initialized := True;

      --  Then the reset of the project path (if any) currently contains the
      --  directories added through Add_Search_Project_Directory

      --  If environment variables are defined and not empty, add their content

      Gpr_Prj_Path_File := Getenv (Gpr_Project_Path_File);
      Gpr_Prj_Path      := Getenv (Gpr_Project_Path);
      Ada_Prj_Path      := Getenv (Ada_Project_Path);

      if Gpr_Prj_Path_File.all /= "" then
         declare
            File : Ada.Text_IO.File_Type;
            Line : String (1 .. 10_000);
            Last : Natural;

         begin
            Open (File, In_File, Gpr_Prj_Path_File.all);

            while not End_Of_File (File) loop
               Get_Line (File, Line, Last);

               if Last /= 0
                 and then (Last = 1 or else Line (1 .. 2) /= "--")
               then
                  Self.Path.Append (Line (1 .. Last));
               end if;

               if Current_Verbosity = High then
                  Debug_Output ("Adding directory to Project_Path: """
                                & Line (1 .. Last) & '"');
               end if;
            end loop;

            Close (File);

         exception
            when others =>
               Write_Str  ("warning: could not read project path file """);
               Write_Str  (Gpr_Prj_Path_File.all);
               Write_Line ("""");
         end;
      end if;

      Free (Gpr_Prj_Path_File);

      if Gpr_Prj_Path.all /= "" then
         Add_Directories (Self, Gpr_Prj_Path.all);
      end if;

      Free (Gpr_Prj_Path);

      if Ada_Prj_Path.all /= "" then
         Add_Directories (Self, Ada_Prj_Path.all);
      end if;

      Free (Ada_Prj_Path);

      --  Scan the directory path to see if "-" is one of the directories.
      --  Remove each occurrence of "-" and set Add_Default_Dir to False.
      --  Also resolve relative paths and symbolic links.

      Index := 2;
      while Index <= Self.Path.Last_Index loop
         --  If the directory is "-", set Add_Default_Dir to False and
         --  remove from path.

         if Self.Path (Index) = No_Project_Default_Dir then
            Add_Default_Dir := False;

            Self.Path.Delete (Index);

         else
            declare
               New_Dir : constant String :=
                           Normalize_Pathname
                             (Self.Path (Index),
                              Resolve_Links => Opt.Follow_Links_For_Dirs);
            begin
               --  If the absolute path was resolved and is different from
               --  the original, replace original with the resolved path.

               if New_Dir /= Self.Path (Index) and then New_Dir /= "" then
                  Self.Path.Replace_Element (Index, New_Dir);
               end if;
            end;

            Index := Index + 1;
         end if;
      end loop;

      --  Set the initial value of Current_Project_Path

      if Add_Default_Dir
        and then Target_Name /= ""
        and then Runtime_Name /= ""
        and then Base_Name (Runtime_Name) /= Runtime_Name
      then
         declare
            Runtime_Dir : constant String :=
                            Normalize_Pathname (Runtime_Name)
                            & Directory_Separator;
         begin
            --  $runtime_dir/lib/gnat

            Self.Path.Append
              (Runtime_Dir & "lib" & Directory_Separator & "gnat");

            --  $runtime_dir/share/gpr

            Self.Path.Append
              (Runtime_Dir & "share" & Directory_Separator & "gpr");
         end;
      end if;
   end Initialize_Default_Project_Path;

   -------------
   -- Iterate --
   -------------

   procedure Iterate
     (Self   : Project_Search_Path;
      Action : not null access procedure (Path : String)) is

      procedure Process (Position : Util.String_Vectors.Cursor);
      --  Calls Action for element at Position

      -------------
      -- Process --
      -------------

      procedure Process (Position : Util.String_Vectors.Cursor) is
      begin
         Action (Util.String_Vectors.Element (Position));
      end Process;

   begin
      Self.Path.Iterate (Process'Access);
   end Iterate;

   --------------
   -- Get_Path --
   --------------

   function Get_Path (Self : Project_Search_Path) return String is
      Length : Integer := Self.Path.Last_Index - 1;
      Index  : Positive := 1;
   begin
      pragma Assert (Is_Initialized (Self));

      for P of Self.Path loop
         Length := Length + P'Length;
      end loop;

      if Self.Path.Is_Empty then
         return "";
      end if;

      return Path : String (1 .. Length) do
         for Idx in Self.Path.First_Index .. Self.Path.Last_Index - 1 loop
            declare
               P : constant Util.String_Vectors.Constant_Reference_Type :=
                     Self.Path (Idx);
            begin
               Path (Index .. Index + P.Element'Length - 1) := P;
               Index := Index + P.Element'Length;
               Path (Index) := Path_Separator;
               Index := Index + 1;
            end;
         end loop;

         Path (Index .. Path'Last) := Self.Path.Last_Element;
      end return;
   end Get_Path;

   --------------
   -- Set_Path --
   --------------

   procedure Set_Path (Self : in out Project_Search_Path; Path : String) is
   begin
      Self.Path := To_Vector (Path);
      Self.Cache.Clear;
   end Set_Path;

   -----------------------
   -- Find_Name_In_Path --
   -----------------------

   function Find_Name_In_Path
     (Self : in out Project_Search_Path;
      Path : String) return String_Access
   is
      use Ada.Strings.Unbounded;
      Current_Dir : Unbounded_String;
      CF : Project_Path_Maps.Cursor;

      function Current_Dir_Cached return String;

      function Current_Dir_Cached return String is
      begin
         if Current_Dir = Null_Unbounded_String then
            Current_Dir := To_Unbounded_String (Get_Current_Dir);
         end if;

         return To_String (Current_Dir);
      end Current_Dir_Cached;

   begin
      if Current_Verbosity = High then
         Debug_Output ("Trying " & Path);
      end if;

      if Is_Absolute_Path (Path) then
         if Check_Filename (Path) then
            return new String'(Path);
         else
            return null;
         end if;
      end if;

      CF := Self.Found.Find (Path);

      if Project_Path_Maps.Has_Element (CF) then
         declare
            P : constant String_Vectors.Constant_Reference_Type :=
                  Self.Path (Project_Path_Maps.Element (CF));
            Candidate : constant String :=
                          (if Is_Absolute_Path (P) then ""
                           else Current_Dir_Cached)
                          & Ensure_Directory (P)
                          & Path;
         begin
            if Check_Filename (Candidate) then
               return new String'(Candidate);
            else
               --  Cache miss
               Self.Found.Clear;
            end if;
         end;
      end if;

      --  Because we don't want to resolve symbolic links, we cannot use
      --  Locate_Regular_File. So, we try each possible path successively.

      for CP in Self.Path.Iterate loop
         Name_Len := 0;

         if not Is_Absolute_Path (Self.Path (CP)) then
            Add_Str_To_Name_Buffer (Current_Dir_Cached);
         end if;

         Add_Str_To_Name_Buffer (Ensure_Directory (Self.Path (CP)));
         Add_Str_To_Name_Buffer (Path);

         if Current_Verbosity = High then
            Debug_Output ("Testing file " & Name_Buffer (1 .. Name_Len));
         end if;

         if Check_Filename (Name_Buffer (1 .. Name_Len)) then
            Self.Found.Insert (Path, String_Vectors.To_Index (CP));

            return new String'(Name_Buffer (1 .. Name_Len));
         end if;
      end loop;

      return null;
   end Find_Name_In_Path;

   ------------------
   -- Find_Project --
   ------------------

   procedure Find_Project
     (Self               : in out Project_Search_Path;
      Project_File_Name  : String;
      Directory          : String;
      Path               : out Path_Name_Type)

   is
      File : constant String :=
               Ensure_Extension (Project_File_Name, Project_File_Extension);
      --  Check if File contains an extension (a dot before a directory
      --  separator). If it is the case we do not try project file with an
      --  added extension as it is not possible to have multiple dots on a
      --  project file name.

      Result : String_Access;
      --  Keep temporary search results here before final conversion into Path

      Normalized : Boolean := False;

      function Is_Regular_File_Cached (Name : String) return Boolean;
      --  Calls GNAT.OS_Lib.Is_Regular_File is Name not found in Self.Cache
      --  and put result into the cache.

      ----------------------------
      -- Is_Regular_File_Cached --
      ----------------------------

      function Is_Regular_File_Cached (Name : String) return Boolean is
         Position : constant Projects_Paths.Cursor := Self.Cache.Find (Name);
      begin
         if Projects_Paths.Has_Element (Position) then
            return Projects_Paths.Element (Position);
         end if;

         return Result : constant Boolean := Is_Regular_File (Name) do
            Self.Cache.Insert (Name, Result);
         end return;
      end Is_Regular_File_Cached;

      function Try_Path_Name is new
        Find_Name_In_Path (Check_Filename => Is_Regular_File_Cached);
      --  Find a file in the project search path

   --  Start of processing for Find_Project

   begin
      pragma Assert (Is_Initialized (Self));

      if Current_Verbosity = High then
         Debug_Increase_Indent
           ("Searching for project """ & File & """ in """ & Directory & '"');
      end if;

      if not Is_Absolute_Path (File) and then Directory /= "" then
         Result :=
           Try_Path_Name
             (Self,
              GNAT.OS_Lib.Normalize_Pathname
                (File,
                 Directory      => Directory,
                 Resolve_Links  => Opt.Follow_Links_For_Files,
                 Case_Sensitive => True));
         Normalized := Result /= null;
      end if;

      if Result = null then
         Result := Try_Path_Name (Self, File);
      end if;

      --  If we cannot find the project file, we return an empty string

      if Result = null then
         Path := No_Path;
         return;

      else
         Path := Get_Path_Name_Id
           (if Normalized then Result.all
            else GNAT.OS_Lib.Normalize_Pathname
              (Result.all,
               Directory      => Directory,
               Resolve_Links  => Opt.Follow_Links_For_Files,
               Case_Sensitive => True));
         Free (Result);
      end if;

      Debug_Decrease_Indent;
   end Find_Project;

   ----------
   -- Free --
   ----------

   procedure Free (Self : in out Project_Search_Path) is
   begin
      Self.Path.Clear;
      Self.Cache.Clear;
   end Free;

   ----------
   -- Copy --
   ----------

   procedure Copy (From : Project_Search_Path; To : out Project_Search_Path) is
   begin
      Free (To);

      To.Path := From.Path;

      --  No need to copy the Cache, it will be recomputed as needed
   end Copy;

   -----------------
   -- Reset_Cache --
   -----------------

   procedure Reset_Cache (Self : in out Project_Search_Path) is
   begin
      Self.Cache.Clear;
   end Reset_Cache;

end GPR.Env;
