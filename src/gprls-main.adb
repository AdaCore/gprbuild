------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                    Copyright (C) 2015-2023, AdaCore                      --
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

with Ada.Characters.Handling;    use Ada.Characters.Handling;
with Ada.Command_Line;           use Ada.Command_Line;
with Ada.Containers.Generic_Sort;
with Ada.Exceptions;             use Ada.Exceptions;
with Ada.Text_IO;                use Ada.Text_IO;

with GNAT.Command_Line; use GNAT.Command_Line;

with GPR.Conf;    use GPR.Conf;
with GPR.Env;     use GPR.Env;
with GPR.Names;   use GPR.Names;
with GPR.Osint;
with GPR.Snames;
with GPR.Tree;
with GPR.Util;    use GPR.Util;

with Gpr_Build_Util; use Gpr_Build_Util;

procedure Gprls.Main is

   use GPR;

   File_Set : Boolean := False;
   --  Set to True by -P switch.
   --  Used to detect multiple -P switches.

   Print_Usage : Boolean := False;
   --  Set to True with switch -h

   Project_File_Name_Expected : Boolean := False;
   --  True when switch "-P" has just been scanned

   Search_Project_Dir_Expected : Boolean := False;
   --  True when last switch was -aP

   Path_Name : String_Access;

   Path_Last : Natural;

   Output_Name : String_Access;

   User_Project_Node : Project_Node_Id;

   No_Project_File_Specified : Boolean := False;

   All_Projects : Boolean := False;

   procedure Initialize;

   procedure Scan_Arg (Argv : String);
   --  Scan and process user specific arguments (Argv is a single argument)

   procedure Usage;
   --  Print usage message

   procedure Display_Closures;
   --  Display output when switch --closure is used

   procedure Display_Output;
   --  Display output when switch --closure is not used

   procedure Display_Paths;
   --  Display source, object and project paths

   procedure Get_Source_Dirs
     (Project    : Project_Id;
      Tree       : Project_Tree_Ref;
      With_State : in out Paths);

   procedure Get_All_Source_Dirs is
     new For_Every_Project_Imported (Paths, Get_Source_Dirs);

   procedure Get_Object_Dirs
     (Project    : Project_Id;
      Tree       : Project_Tree_Ref;
      With_State : in out Paths);

   procedure Get_All_Object_Dirs is
        new For_Every_Project_Imported (Paths, Get_Object_Dirs);

   procedure Get_Runtime_Object_Dirs
     (Project    : Project_Id;
      Tree       : Project_Tree_Ref;
      With_State : in out Paths);

   procedure Get_All_Runtime_Object_Dirs is
      new For_Every_Project_Imported (Paths, Get_Runtime_Object_Dirs);

   procedure Look_For_Sources;
   --  Get the source ids

   subtype One_Range is Integer range -1 .. 1;

   function Compare (Left, Right : String) return One_Range is
     (if Left > Right then 1 elsif Left = Right then 0 else -1);

   function Get_Tree_Name (Index : Positive) return String;
   --  Get main project name of the source taken by Index from File_Names
   --  container.

   function Before (Left, Right : Positive) return Boolean
   is
     (case Compare (Get_Tree_Name (Left), Get_Tree_Name (Right)) is
      when  1 => False,
      when -1 => True,
      when  0 =>
        (case Compare
           (File_Names (Left).File_Name, File_Names (Right).File_Name)
         is
         when  1 => False,
         when -1 => True,
         when  0 => File_Names (Left).Source.Path.Display_Name
                    < File_Names (Right).Source.Path.Display_Name));
   --  Returns True if element of the File_Names in Left position have to be
   --  before the element in Right position.

   procedure Swap_File_Names (Left, Right : Positive);
   --  Swap 2 elements in File_Names vector

   procedure Do_List (Project : Project_Id; Tree : Project_Tree_Ref);
   --  Iterates over project or over aggregated projects to prepare the source
   --  list to process.

   procedure Sort_File_Names is new Ada.Containers.Generic_Sort
     (Index_Type => Positive,
      Before     => Before,
      Swap       => Swap_File_Names);
   --  Sort File_Names vector declared in the GPRls specification

   ----------------------
   -- Display_Closures --
   ----------------------

   procedure Display_Closures is
   begin
      if File_Names.Is_Empty then
         Fail_Program (Project_Tree, "no main specified for closure");

      else
         declare
            The_Sources : String_Vectors.Vector;
            Result : String_Vectors.Vector;
            Status : GPR.Util.Status_Type;

         begin
            for FN_Source of File_Names loop
               if FN_Source.Source /= No_Source then
                  The_Sources.Append
                    (Get_Name_String (FN_Source.Source.File));
               end if;
            end loop;

            if The_Sources.Is_Empty then
               Finish_Program (Project_Tree);
            end if;

            Get_Closures
              (Project                  => Main_Project,
               In_Tree                  => Project_Tree,
               Mains                    => The_Sources,
               All_Projects             => True,
               Include_Externally_Built => True,
               Status                   => Status,
               Result                   => Result);

            New_Line;

            if Status = Incomplete_Closure then
               Put_Line
                 ((if The_Sources.Last_Index = 1 then "Incomplete closure:"
                   else "Incomplete closures:"));

            elsif Status = GPR.Util.Success then
               Put_Line
                 ((if The_Sources.Last_Index = 1 then "Closure:"
                   else "Closures:"));

            else
               Fail_Program
                 (Project_Tree, "unable to get closures: " & Status'Img);
            end if;

            New_Line;

            if not Result.Is_Empty then
               for Res of Result loop
                  Put_Line ("  " & Res);
               end loop;

               New_Line;
            end if;
         end;
      end if;
   end Display_Closures;

   --------------------
   -- Display_Output --
   --------------------

   procedure Display_Output is
   begin
      if Very_Verbose_Mode then
         --  First the ALI files that are not found

         for FN_Source of File_Names loop
            if FN_Source.Source /= No_Source
              and then FN_Source.The_ALI = No_ALI_Id
            then
               GNATDIST.Output_No_ALI (FN_Source);
            end if;
         end loop;

         --  Then the ALI that have been found

         for FN_Source of File_Names loop
            if FN_Source.Source /= No_Source
              and then FN_Source.The_ALI /= No_ALI_Id
            then
               GNATDIST.Output_ALI (FN_Source);
            end if;
         end loop;

      else
         for FN_Source of File_Names loop
            declare
               Id        : ALI_Id;
               Last_U    : Unit_Id;

            begin
               if FN_Source.Source /= No_Source then
                  Id := FN_Source.The_ALI;

                  if Id = No_ALI_Id then
                     null;

                  else
                     Get_Name_String
                       (Units.Table (ALIs.Table (Id).First_Unit).Uname);

                     if Print_Object then
                        Output_Object
                          ((if ALIs.Table (Id).No_Object then No_File
                            else ALIs.Table (Id).Ofile_Full_Name));
                     end if;

                     --  In verbose mode print all main units in the ALI file,
                     --  otherwise just print the first one to ease columnwise
                     --  printout.

                     Last_U :=
                       (if Verbose_Mode then ALIs.Table (Id).Last_Unit
                        else ALIs.Table (Id).First_Unit);

                     for U in ALIs.Table (Id).First_Unit .. Last_U loop
                        if Print_Unit then
                           Output_Unit (U);
                        end if;

                        --  Output source now, unless if it will be done as
                        --  part of outputing dependencies.

                        if not (Dependable and then Print_Source) then
                           Output_Source
                             (FN_Source.Source,
                              Corresponding_Sdep_Entry (Id, U));
                        end if;
                     end loop;

                     --  Print out list of units on which this unit depends (D
                     --  lines).

                     if Dependable and then Print_Source then
                        if Verbose_Mode then
                           Put_Line ("   depends upon");
                        end if;

                        for D in
                          ALIs.Table (Id).First_Sdep ..
                          ALIs.Table (Id).Last_Sdep
                        loop
                           if
                           not Is_Ada_Predefined_File_Name
                                 (Sdep.Table (D).Sfile)
                           then
                              Put ("   ");
                              Output_Source (FN_Source.Tree, D);
                           end if;
                        end loop;
                     end if;
                  end if;
               end if;
            end;
         end loop;
      end if;
   end Display_Output;

   -------------------
   -- Display_Paths --
   -------------------

   procedure Display_Paths is
      Source_Paths : Paths := No_Paths;
      Object_Paths : Paths := No_Paths;

      Path : Path_Access;

      procedure Put_Path (Path : String);
      --  Put path prefixed with 3 spaces to standard output add directory
      --  separator at the end if absent.

      --------------
      -- Put_Path --
      --------------

      procedure Put_Path (Path : String) is
      begin
         if Path'Length > 1
           and then Path (Path'Last - 1 .. Path'Last)
                    = (1 .. 2 => Directory_Separator)
         then
            Put_Path (Path (Path'First .. Path'Last - 1));
            return;
         end if;

         Put ("   ");
         Put (Path);

         if Path (Path'Last) /= Directory_Separator then
            Put_Line ("" & Directory_Separator);
         else
            New_Line;
         end if;
      end Put_Path;

   begin
      New_Line;
      Display_Version ("GPRLS", "2015");

      New_Line;
      Put_Line ("Source Search Path:");

      --  First the source directories

      Get_All_Source_Dirs (Main_Project, Project_Tree, Source_Paths);

      --  Then the runtime source directories, if any

      Get_All_Runtime_Source_Dirs (Main_Project, Project_Tree, Source_Paths);

      Path := Source_Paths.First;
      while Path /= null loop
         Put_Path (Path.Path.all);
         Path := Path.Next;
      end loop;

      New_Line;
      Put_Line ("Object Search Path:");

      --  First the object directories

      Get_All_Object_Dirs (Main_Project, Project_Tree, Object_Paths);

      --  Then the runtime library directories, if any

      Get_All_Runtime_Object_Dirs (Main_Project, Project_Tree, Object_Paths);

      Path := Object_Paths.First;
      while Path /= null loop
         Put_Path (Path.Path.all);
         Path := Path.Next;
      end loop;

      New_Line;
      Put_Line ("Project Search Path:");

      declare
         procedure Output (Path : String);
         --  Calls Put_Path with Path parameter if Path is not "."

         ------------
         -- Output --
         ------------

         procedure Output (Path : String) is
         begin
            if Path /= "." then
               Put_Path (Path);
            end if;
         end Output;

      begin
         Put_Line ("   <Current_Directory>");
         Iterate (Root_Environment.Project_Path, Output'Access);
      end;

      New_Line;
   end Display_Paths;

   ---------------------
   -- Get_Object_Dirs --
   ---------------------

   procedure Get_Object_Dirs
     (Project    : Project_Id;
      Tree       : Project_Tree_Ref;
      With_State : in out Paths)
   is
      pragma Unreferenced (Tree);
      Name : Path_Name_Type := No_Path;
   begin
      case Project.Qualifier is
         when Aggregate | Abstract_Project | Configuration =>
            null;

         when Library | Aggregate_Library =>
            Name := Project.Library_ALI_Dir.Display_Name;

            if Name = No_Path then
               Name := Project.Library_Dir.Display_Name;
            end if;

         when Unspecified | GPR.Standard =>
            Name := Project.Object_Directory.Display_Name;
      end case;

      if Name /= No_Path then
         Add (Get_Name_String (Name),  With_State);
      end if;
   end Get_Object_Dirs;

   -----------------------------
   -- Get_Runtime_Object_Dirs --
   -----------------------------

   procedure Get_Runtime_Object_Dirs
     (Project    : Project_Id;
      Tree       : Project_Tree_Ref;
      With_State : in out Paths)
   is
      List : Language_Ptr := Project.Languages;
      Dirs : Name_List_Index;
      Nam_Nod : Name_Node;
   begin
      while List /= No_Language_Index loop
         Dirs := List.Config.Runtime_Library_Dirs;
         while Dirs /= No_Name_List loop
            Nam_Nod := Tree.Shared.Name_Lists.Table (Dirs);
            Add (Get_Name_String (Nam_Nod.Name), With_State);
            Dirs := Nam_Nod.Next;
         end loop;

         List := List.Next;
      end loop;
   end Get_Runtime_Object_Dirs;

   ---------------------
   -- Get_Source_Dirs --
   ---------------------

   procedure Get_Source_Dirs
     (Project    : Project_Id;
      Tree       : Project_Tree_Ref;
      With_State : in out Paths)
   is
      Source_Dirs : String_List_Id := Project.Source_Dirs;
   begin
      while Source_Dirs /= Nil_String loop
         Add
           (Get_Name_String
              (Tree.Shared.String_Elements.Table (Source_Dirs).Display_Value),
            With_State);
         Source_Dirs := Tree.Shared.String_Elements.Table (Source_Dirs).Next;
      end loop;
   end Get_Source_Dirs;

   -------------------
   -- Get_Tree_Name --
   -------------------

   function Get_Tree_Name (Index : Positive) return String is
      Tree : constant Project_Tree_Ref := File_Names (Index).Tree;
   begin
      return
        (if Tree = null then ""
         else Get_Name_String (Tree.Projects.Project.Name));
   end Get_Tree_Name;

   ----------------------
   -- Look_For_Sources --
   ----------------------

   procedure Look_For_Sources is
   begin
      for FN_Source of File_Names loop
         if FN_Source.Source = No_Source then
            Put_Line
              (Standard_Error,
               "Can't find source for " & FN_Source.File_Name);

         elsif FN_Source.Source.Dep_Path = No_Path then
            Put_Line
              (Standard_Error,
               "Can't find ALI file for "
               & Get_Name_String (FN_Source.Source.Path.Display_Name));

         else
            declare
               Text   : Text_Buffer_Ptr;
               Source : constant GPR.Source_Id := FN_Source.Source;

            begin
               Text := Osint.Read_Library_Info
                 (File_Name_Type (Source.Dep_Path));

               --  If the ALI file cannot be found and the project is an
               --  externally built library project, look for the ALI file
               --  in the library directory.

               if Text = null and then
                  Source.Project.Externally_Built and then
                  Source.Project.Library
               then
                  declare
                     Dep_Path_Name : constant String :=
                       Get_Name_String (Source.Project.Library_Dir.Name) &
                       Directory_Separator &
                       Get_Name_String (Source.Dep_Name);
                     Dep_Path : File_Name_Type;

                  begin
                     Set_Name_Buffer (Dep_Path_Name);
                     Dep_Path := Name_Find;
                     Text := Osint.Read_Library_Info (Dep_Path);
                  end;
               end if;

               if Text /= null then
                  FN_Source.The_ALI := Scan_ALI
                    (F           => File_Name_Type (Source.Dep_Path),
                     T           => Text,
                     Ignore_ED   => False,
                     Err         => True,
                     Read_Lines  => "WD",
                     Object_Path => File_Name_Type (Source.Object_Path));
                  Free (Text);

               else
                  FN_Source.The_ALI := No_ALI_Id;

                  if Very_Verbose_Mode then
                     --  With switch -V, when the ALI file is not found, this
                     --  will be reported in the output later.

                     null;

                  else
                     Put_Line
                       (Standard_Error,
                        "Can't find ALI file for "
                        & Get_Name_String (Source.Path.Display_Name));
                  end if;
               end if;
            end;
         end if;
      end loop;
   end Look_For_Sources;

   --------------
   -- Scan_Arg --
   --------------

   procedure Scan_Arg (Argv : String) is
      FD  : File_Descriptor;
      Len : Integer;
      OK  : Boolean;

   begin
      pragma Assert (Argv'First = 1);

      if Argv'Length = 0 then
         return;
      end if;

      OK := True;

      --  -P xxx

      if Project_File_Name_Expected then
         if Argv (1) = '-' then
            Fail ("project file name missing");

         else
            File_Set                   := True;
            Project_File_Name          := new String'(Argv);
            Project_File_Name_Expected := False;
         end if;

      --  -aP xxx

      elsif Search_Project_Dir_Expected then
         if Argv (1) = '-' then
            Fail ("directory name missing after -aP");
         else
            Search_Project_Dir_Expected := False;
            Add_Directories
              (Root_Environment.Project_Path, Argv, Prepend => True);
         end if;

      elsif Argv (1) = '-' then
         if Argv'Length = 1 then
            Fail ("switch character '-' cannot be followed by a blank");

         --  Forbid -?- or -??- where ? is any character

         elsif (Argv'Length = 3 and then Argv (3) = '-')
           or else (Argv'Length = 4 and then Argv (4) = '-')
         then
            Fail ("Trailing ""-"" at the end of " & Argv & " forbidden.");

         --  Processing for -aP<dir>

         elsif Argv'Length >= 3 and then Argv (1 .. 3) = "-aP" then

            if Argv'Length = 3 then
               Search_Project_Dir_Expected := True;

            else
               Add_Directories
                 (Root_Environment.Project_Path,
                  Argv (4 .. Argv'Last),
                  Prepend => True);
            end if;

         --  Processing for --unchecked-shared-lib-imports

         elsif Argv = "--unchecked-shared-lib-imports" then
            Opt.Unchecked_Shared_Lib_Imports := True;

         elsif Argv = "--closure" then
            Closure    := True;

         --  Processing for one character switches

         elsif Argv'Length = 2 then
            case Argv (2) is
               when 'a' => null; -- ??? To be implemented
               when 'h' => Print_Usage               := True;
               when 'u' => Reset_Print; Print_Unit   := True;
               when 'U' => All_Projects              := True;
               when 's' => Reset_Print; Print_Source := True;
               when 'o' => Reset_Print; Print_Object := True;
               when 'v' =>
                  Verbose_Mode    := True;
                  Verbosity_Level := High;
               when 'd' => Dependable                := True;
               when 'V' => Very_Verbose_Mode         := True;

               when 'P' =>
                  if File_Set then
                     Fail ("only one -P switch may be specified");
                  end if;

                  Project_File_Name_Expected := True;

               when others => OK := False;
            end case;

         elsif Argv'Length = 4 and then Argv (2 .. 3) = "vP" then
            case Argv (4) is
               when '0' => Current_Verbosity := Default;
               when '1' => Current_Verbosity := Medium;
               when '2' => Current_Verbosity := High;
               when others => OK := False;
            end case;

         --  -Pxxx

         elsif Argv'Length > 2 and then Argv (2) = 'P' then
            if File_Set then
               Fail ("only one -P switch may be specified");
            end if;

            File_Set          := True;
            Project_File_Name := new String'(Argv (3 .. Argv'Last));

         --  Processing for -files=file

         elsif Argv'Length > 7 and then Argv (1 .. 7) = "-files=" then
            FD := Open_Read (Argv (8 .. Argv'Last), GNAT.OS_Lib.Text);

            if FD = Invalid_FD then
               Osint.Fail ("could not find text file """ &
                           Argv (8 .. Argv'Last) & '"');
            end if;

            Len := Integer (File_Length (FD));

            declare
               Buffer : String (1 .. Len + 1);
               Index  : Positive := 1;
               Last   : Positive;

            begin
               --  Read the file

               Len := Read (FD, Buffer (1)'Address, Len);
               Buffer (Buffer'Last) := ASCII.NUL;
               Close (FD);

               --  Scan the file line by line

               while Index < Buffer'Last loop

                  --  Find the end of line

                  Last := Index;
                  while Last <= Buffer'Last
                    and then Buffer (Last) /= ASCII.LF
                    and then Buffer (Last) /= ASCII.CR
                  loop
                     Last := Last + 1;
                  end loop;

                  --  Ignore empty lines

                  if Last > Index then
                     Add_File (Buffer (Index .. Last - 1), No_Project_Tree);
                  end if;

                  --  Find the beginning of the next line

                  Index := Last;
                  while Buffer (Index) = ASCII.CR or else
                        Buffer (Index) = ASCII.LF
                  loop
                     Index := Index + 1;
                  end loop;
               end loop;
            end;

         elsif Argv'Length > Target_Project_Option'Length
           and then
             Argv (1 .. Target_Project_Option'Length) =
           Target_Project_Option
         then
            if Target_Name /= null then
               if Target_Name.all /=
                 Argv (Target_Project_Option'Length + 1
                      .. Argv'Last)
               then
                  Fail_Program
                    (Project_Tree,
                     "several target switches "
                     & "cannot be specified");
               end if;

            else
               Target_Name :=
                 new String'
                   (Argv (Target_Project_Option'Length + 1
                    .. Argv'Last));
            end if;

         --  Processing for --RTS=path

         elsif Argv'Length >= 5 and then Argv (1 .. 5) = "--RTS" then
            if Argv'Length <= 6 or else Argv (6) /= '='then
               Osint.Fail ("missing path for --RTS");

            else
               --  Check that it is the first time we see this switch or, if
               --  it is not the first time, the same path is specified.

               if RTS_Specified = null then
                  RTS_Specified := new String'(Argv (7 .. Argv'Last));
                  Set_Runtime_For
                    (Snames.Name_Ada, Argv (7 .. Argv'Last));

               elsif RTS_Specified.all /= Argv (7 .. Argv'Last) then
                  Osint.Fail ("--RTS cannot be specified multiple times");
               end if;
            end if;

         elsif Argv'Length >= 3
           and then Argv (2) = 'X'
           and then Is_External_Assignment (Root_Environment, Argv)
         then
            --  Is_External_Assignment has side effects when it returns True

            null;

         else
            OK := False;
         end if;

      --  If not a switch, it must be a file name

      else
         Add_File (Argv, No_Project_Tree);
      end if;

      if not OK then
         Put ("warning: unknown switch """);
         Put (Argv);
         Put_Line ("""");
      end if;

   end Scan_Arg;

   ---------------------
   -- Swap_File_Names --
   ---------------------

   procedure Swap_File_Names (Left, Right : Positive) is
   begin
      File_Names.Swap (Left, Right);
   end Swap_File_Names;

   -----------
   -- Usage --
   -----------

   procedure Usage is
   begin
      --  Usage line

      Put_Line ("Usage: gprls switches  [list of object files]");
      New_Line;

      --  GPRLS switches

      Put_Line ("switches:");

      Display_Usage_Version_And_Help;

      --  Line for -Pproj

      Put_Line ("  -Pproj       Use project file proj");

      --  Line for -a

      Put_Line ("  -a           Also output relevant predefined units");

      --  Line for -u

      Put_Line ("  -u           Output only relevant unit names");

      --  Line for -U

      Put_Line ("  -U           List sources for all projects");

      --  Line for -h

      Put_Line ("  -h           Output this help message");

      --  Line for -s

      Put_Line ("  -s           Output only relevant source names");

      --  Line for -o

      Put_Line ("  -o           Output only relevant object names");

      --  Line for -d

      Put_Line ("  -d           Output sources on which specified units " &
                               "depend");

      --  Line for -v

      Put_Line ("  -v           Verbose output, full path and unit " &
                               "information");

      --  Line for -vPx

      Put_Line ("  -vPx         Specify verbosity when parsing project " &
                  "files (x = 0/1/2)");

      --  Line for --closure

      Put_Line ("  --closure    List paths of sources in closures of mains");

      New_Line;
      --  Line for -files=

      Put_Line ("  -files=fil   Files are listed in text file 'fil'");

      --  Line for -aP switch

      Put_Line ("  -aP dir      Add directory dir to project search path");

      --  Line for --target=

      Put_Line ("  --target=xxx Specify target xxx");

      --  Line for --RTS

      Put_Line ("  --RTS=dir    Specify the Ada runtime");

      --  Line for --unchecked-shared-lib-imports

      Put_Line ("  --unchecked-shared-lib-imports");
      Put_Line
        ("               Shared library projects may import any project");

      --  Line for -X

      Put_Line ("  -Xnm=val     Specify an external reference for " &
                  "project files");

      --  File Status explanation

      New_Line;
      Put_Line (" File status can be:");

      for ST in File_Status loop
         Put ("   ");
         Output_Status (ST, Verbose => False);
         Put (" ==> ");
         Output_Status (ST, Verbose => True);
         New_Line;
      end loop;
   end Usage;

   procedure Check_Version_And_Help is new Check_Version_And_Help_G (Usage);

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      if not Initialized then
         Initialized := True;

         --  Initialize some packages

         Snames.Initialize;

         Set_Program_Name ("gprls");

         GPR.Tree.Initialize (Root_Environment, Gprls_Flags);
         GPR.Tree.Initialize (Project_Node_Tree);

         GPR.Initialize (Project_Tree);

         GPR.Tree.Initialize (Tree);
      end if;
   end Initialize;

   --------------
   -- _Do_List --
   --------------

   procedure Do_List
     (Project : Project_Id; Tree : Project_Tree_Ref)
   is
      Iter   : Source_Iterator := For_Each_Source (Tree);
      Source : GPR.Source_Id;
   begin
      loop
         Source := Element (Iter);
         exit when Source = No_Source;
         Initialize_Source_Record (Source);
         Next (Iter);
      end loop;

      if Closure and then No_Files_In_Command_Line then
         --  Get the mains declared in the main project

         declare
            Mains : String_List_Id := Project.Mains;
            Elem : String_Element;
         begin
            while Mains /= Nil_String loop
               Elem := Tree.Shared.String_Elements.Table (Mains);
               Add_File (Get_Name_String (Elem.Value), Tree);
               Mains := Elem.Next;
            end loop;
         end;
      end if;

      if No_Files_In_Command_Line and not Closure then
         --  Get all the compilable sources of the project
         declare
            Unit    : GPR.Unit_Index;
            Subunit : Boolean := False;
         begin
            Unit := Units_Htable.Get_First (Tree.Units_HT);
            while Unit /= No_Unit_Index loop

               --  We only need to put the library units, body or spec, but not
               --  the subunits.

               if Unit.File_Names (Impl) /= null
                 and then not Unit.File_Names (Impl).Locally_Removed
               then
                  --  There is a body, check if it is for this project

                  if All_Projects
                    or else Unit.File_Names (Impl).Project = Project
                  then
                     Subunit := False;

                     if Unit.File_Names (Spec) = null
                       or else Unit.File_Names (Spec).Locally_Removed
                     then
                        --  We have a body with no spec: we need to check if
                        --  this is a subunit, because gnatls will complain
                        --  about subunits.

                        Subunit := Is_Subunit (Unit.File_Names (Impl));
                     end if;

                     if not Subunit then
                        Add_File
                          (Get_Name_String (Unit.File_Names (Impl).Object),
                           Tree,
                           Source => Unit.File_Names (Impl));
                     end if;
                  end if;

               elsif Unit.File_Names (Spec) /= null
                 and then not Unit.File_Names (Spec).Locally_Removed
                 and then
               --  We have a spec with no body. Check if it is for this project
                 (All_Projects
                  or else Unit.File_Names (Spec).Project = Project)
               then
                  Add_File
                    (Get_Name_String (Unit.File_Names (Spec).Object),
                     Tree,
                     Source => Unit.File_Names (Spec));
               end if;

               Unit := Units_Htable.Get_Next (Tree.Units_HT);
            end loop;
         end;

      else
         --  Find the sources in the project files

         for FN_Source of File_Names loop
            declare
               File_Name : String renames FN_Source.File_Name;
               Unit      : GPR.Unit_Index;
               Subunit   : Boolean := False;
            begin
               Canonical_Case_File_Name (File_Name);

               Unit := Units_Htable.Get_First (Tree.Units_HT);

               Unit_Loop :
               while Unit /= No_Unit_Index loop

                  --  We only need to put the library units, body or spec, but
                  --  not the subunits.

                  if Unit.File_Names (Impl) /= null
                    and then not Unit.File_Names (Impl).Locally_Removed
                  then
                     --  There is a body, check if it is for this project

                     if All_Projects
                       or else
                         Ultimate_Extending_Project_Of
                           (Unit.File_Names (Impl).Project) = Project
                     then
                        Subunit := False;

                        if Unit.File_Names (Spec) = null
                          or else Unit.File_Names (Spec).Locally_Removed
                        then
                           --  We have a body with no spec: we need to check if
                           --  this is a subunit, because gnatls will complain
                           --  about subunits.

                           Subunit := Is_Subunit (Unit.File_Names (Impl));
                        end if;

                        if not Subunit then
                           declare
                              Object_Name : String :=
                                Get_Name_String
                                  (Unit.File_Names (Impl).Object);
                              Dep_Name : String :=
                                Get_Name_String
                                  (Unit.File_Names (Impl).Dep_Name);
                           begin
                              Canonical_Case_File_Name (Object_Name);
                              Canonical_Case_File_Name (Dep_Name);

                              if Dep_Name in File_Name | File_Name & ".ali"
                                or else File_Name in Object_Name
                                  | Get_Name_String
                                    (Unit.File_Names (Impl).File)
                                      | Get_Name_String
                                        (Unit.File_Names (Impl)
                                         .Display_File)
                              then
                                 FN_Source.Source := Unit.File_Names (Impl);
                                 FN_Source.Tree   := Tree;
                                 exit Unit_Loop;
                              end if;
                           end;
                        end if;
                     end if;

                  elsif Unit.File_Names (Spec) /= null
                    and then not Unit.File_Names (Spec).Locally_Removed
                    and then
                  --  We have a spec with no body. Check if it is for this
                  --  project.
                    (All_Projects
                     or else Unit.File_Names (Spec).Project = Project)
                  then
                     declare
                        Object_Name : String :=
                          Get_Name_String (Unit.File_Names (Spec).Object);
                        Dep_Name : String :=
                          Get_Name_String (Unit.File_Names (Spec).Dep_Name);
                     begin
                        Canonical_Case_File_Name (Object_Name);
                        Canonical_Case_File_Name (Dep_Name);

                        if Dep_Name in File_Name | File_Name & ".ali"
                          or else File_Name in Object_Name
                            | Get_Name_String
                              (Unit.File_Names (Spec).File)
                                | Get_Name_String
                                  (Unit.File_Names (Spec).Display_File)
                        then
                           FN_Source.Source := Unit.File_Names (Spec);
                           FN_Source.Tree   := Tree;
                        end if;
                     end;
                  end if;

                  Unit := Units_Htable.Get_Next (Tree.Units_HT);
               end loop Unit_Loop;
            end;
         end loop;
      end if;

      --  Create mapping of ALI files to Source_Id

      --  Get all the compilable sources of the projects
      declare
         Unit    : GPR.Unit_Index;
         Subunit : Boolean := False;
      begin
         Unit := Units_Htable.Get_First (Tree.Units_HT);
         while Unit /= No_Unit_Index loop

            --  We only need to put the library units, body or spec, but not
            --  the subunits.

            if Unit.File_Names (Impl) /= null
              and then not Unit.File_Names (Impl).Locally_Removed
            then
               Subunit := False;

               if Unit.File_Names (Spec) = null
                 or else Unit.File_Names (Spec).Locally_Removed
               then
                  --  We have a body with no spec: we need to check if this is
                  --  a subunit.

                  Subunit := Is_Subunit (Unit.File_Names (Impl));
               end if;

               if not Subunit then
                  Add_ALI
                    (Unit.File_Names (Impl).File,
                     Spec   => False,
                     Source => Unit.File_Names (Impl));
               end if;
            end if;

            if Unit.File_Names (Spec) /= null
              and then not Unit.File_Names (Spec).Locally_Removed
            then
               Add_ALI
                 (Unit.File_Names (Spec).File,
                  Spec   => True,
                  Source => Unit.File_Names (Spec));
            end if;

            Unit := Units_Htable.Get_Next (Tree.Units_HT);
         end loop;
      end;
   end Do_List;

   procedure For_All_And_Aggregated is new For_Project_And_Aggregated
     (Do_List);

begin
   Initialize;

   --  Add the external variable GPR_TOOL (default value "gprbuild")

   Add_Gpr_Tool_External;

   Check_Version_And_Help ("GPRLS", "2015");

   Project_File_Name_Expected := False;

   --  Loop to scan out arguments

   Next_Arg := 1;
   Scan_Args : while Next_Arg <= Argument_Count loop
      declare
         Next_Argv : constant String := Argument (Next_Arg);
      begin
         Scan_Arg (Next_Argv);
      end;

      Next_Arg := Next_Arg + 1;
   end loop Scan_Args;

   No_Files_In_Command_Line := File_Names.Is_Empty;

   if Very_Verbose_Mode then
      Closure    := False;
      Dependable := False;

      if not File_Names.Is_Empty then
         All_Projects := True;
      end if;

   elsif Closure then
      Dependable := False;
   end if;

   if Project_File_Name_Expected then
      Fail ("project file name missing");

   elsif Search_Project_Dir_Expected then
      Fail ("directory name missing after -aP");
   end if;

   --  Output usage information when requested

   if Print_Usage then
      Usage;
   end if;

   if Project_File_Name = null
     and then File_Names.Is_Empty
     and then not Verbose_Mode
   then
      if Argument_Count = 0 then
         Usage;

      else
         Try_Help;
         Exit_Status := E_Fatal;
      end if;

      Exit_Program (Exit_Status);
   end if;

   Save_Verbose         := Verbose_Mode;
   Save_Verbosity_Level := Verbosity_Level;

   No_Project_File_Specified := Project_File_Name = null;

   if Verbose_Mode and then
     No_Project_File_Specified and then
     File_Names.Is_Empty
   then
      Verbose_Mode    := False;
      Verbosity_Level := None;
      Quiet_Output    := True;
   end if;

   if Load_Standard_Base then
      Knowledge.Parse_Knowledge_Base (Project_Tree);
   end if;

   if Target_Name = null then
      GPR.Env.Initialize_Default_Project_Path
        (Root_Environment.Project_Path,
         Target_Name  => Knowledge.Normalized_Hostname,
         Runtime_Name => Runtime_Name_For (Snames.Name_Ada));

   else
      GPR.Env.Initialize_Default_Project_Path
        (Root_Environment.Project_Path,
         Target_Name  => Target_Name.all,
         Runtime_Name => Runtime_Name_For (Snames.Name_Ada));
   end if;

   if Project_File_Name = null then
      Look_For_Default_Project (Never_Fail => True);
   end if;

   if Project_File_Name = null then
      Try_Help;
      Fail_Program (null, "no project file specified");
   end if;

   Path_Name := new
     String (1 .. Project_File_Name'Length + Project_File_Extension'Length);
   Path_Last := Project_File_Name'Length;

   Path_Name (1 .. Path_Last) :=
     (if File_Names_Case_Sensitive then Project_File_Name.all
      else To_Lower (Project_File_Name.all));

   Path_Name (Path_Last + 1 .. Path_Name'Last) :=
     Project_File_Extension;

   if Path_Last < Project_File_Extension'Length + 1
     or else Path_Name
       (Path_Last - Project_File_Extension'Length + 1 .. Path_Last)
     /= Project_File_Extension
   then
      Path_Last := Path_Name'Last;
   end if;

   Output_Name := new String'(Path_Name (1 .. Path_Last));

   if Target_Name = null then
      Target_Name := new String'("");
   end if;

   if Config_Project_File_Name = null then
      Config_Project_File_Name := new String'("");
   end if;

   Opt.Warning_Mode := Suppress;

   begin
      Main_Project := No_Project;
      Parse_Project_And_Apply_Config
        (Main_Project               => Main_Project,
         User_Project_Node          => User_Project_Node,
         Config_File_Name           => Config_Project_File_Name.all,
         Autoconf_Specified         => False,
         Project_File_Name          => Output_Name.all,
         Project_Tree               => Project_Tree,
         Project_Node_Tree          => Project_Node_Tree,
         Packages_To_Check          => Packages_To_Check,
         Env                        => Root_Environment,
         Allow_Automatic_Generation => True,
         Automatically_Generated    => Delete_Autoconf_File,
         Config_File_Path           => Configuration_Project_Path,
         Target_Name                => Target_Name.all,
         Normalized_Hostname        => Knowledge.Normalized_Hostname,
         Implicit_Project           => No_Project_File_Found);

   exception
      when E : GPR.Conf.Invalid_Config =>
         Fail_Program (Project_Tree, Exception_Message (E));
   end;

   if Main_Project = No_Project then
      Fail_Program
        (Project_Tree,
         "unable to process project file " & Output_Name.all);
   end if;

   Verbose_Mode    := Save_Verbose;
   Verbosity_Level := Save_Verbosity_Level;
   Quiet_Output    := False;

   if Verbose_Mode then
      Display_Paths;

      if No_Project_File_Specified and then File_Names.Is_Empty then
         Finish_Program (Project_Tree);
      end if;
   end if;

   Set_Gprls_Mode;

   For_All_And_Aggregated (Main_Project, Project_Tree);

   if No_Files_In_Command_Line then
      Sort_File_Names (File_Names.First_Index, File_Names.Last_Index);

      --  Remove duplicates

      declare
         Idx : Natural := File_Names.First_Index + 1;
         function Same_Path (Left, Right : GPR.Source_Id) return Boolean is
           (No_Source not in Left | Right
            and then (Left = Right or else Left.Path = Right.Path));
      begin
         while Idx <= File_Names.Last_Index loop
            if Same_Path (File_Names (Idx - 1).Source, File_Names (Idx).Source)
              and then File_Names (Idx - 1).Source.Project.Name
                       = File_Names (Idx).Source.Project.Name
            then
               File_Names.Delete (Idx);
            else
               Idx := Idx + 1;
            end if;
         end loop;
      end;
   end if;

   Look_For_Sources;

   if Closure then
      Display_Closures;
   else
      Display_Output;
   end if;

   Finish_Program (Project_Tree);
end Gprls.Main;
