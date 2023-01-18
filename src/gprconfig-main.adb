------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2006-2023, AdaCore                     --
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

with Ada.Command_Line;
with Ada.Containers;            use Ada.Containers;
with Ada.Exceptions;            use Ada.Exceptions;
with Ada.Strings.Unbounded;     use Ada.Strings.Unbounded;
with Ada.Text_IO;               use Ada.Text_IO;

with GNAT.Command_Line;         use GNAT.Command_Line;
with GNAT.OS_Lib;               use GNAT.OS_Lib;

with GPR.Knowledge;       use GPR.Knowledge;
with GPR;                 use GPR;
with GPR.Names;           use GPR.Names;
with GPR.Opt;
with GPR.Sdefault;
with GPR.Util;

procedure GprConfig.Main is

   Output_File : Unbounded_String :=
                   To_Unbounded_String (GPR.Util.Default_Config_Name);
   --  Init with name of the configuration file used by gprbuild by default

   Selected_Targets_Set : Targets_Set_Id;
   --  Targets set id for the selected target

   Opt_Validate : Boolean := False;
   --  Whether we should validate the contents of the knowledge base

   use Compiler_Lists;

   procedure Help (Base : Knowledge_Base);
   --  Display list of switches

   procedure Usage;
   --  Display list of options, no specific to current invocation, to be used
   --  when switch --help is used.

   procedure Check_Version_And_Help is
     new Util.Check_Version_And_Help_G (Usage);

   procedure Display_Compilers_For_Parser
     (Base      : in out Knowledge_Base;
      Compilers : in out Compiler_Lists.List);
   --  Display the list of found compilers for use by an external parser

   procedure Select_Compilers_Interactively
     (Base      : in out Knowledge_Base;
      Compilers : in out Compiler_Lists.List);
   --  Ask the user for compilers to be selected

   procedure Show_Command_Line_Config (Compilers : Compiler_Lists.List);
   --  Display the batch command line that would have the same effect as the
   --  current selection of compilers.

   type Boolean_Array  is array (Count_Type range <>) of Boolean;

   type All_Iterator (Count : Count_Type) is new Compiler_Iterator with
      record
         Filter_Matched : Boolean_Array (1 .. Count) := (others => False);
         Filters        : Compiler_Lists.List;
         Compilers      : Compiler_Lists.List;
      end record;

   procedure Callback
     (Iterator          : in out All_Iterator;
      Base              : in out Knowledge_Base;
      Comp              : Compiler;
      Runtime_Specified : Boolean;
      From_Extra_Dir    : Boolean;
      Continue          : out Boolean);
   --  Search all compilers on path, preselecting the first one matching each
   --  of the filters.

   Base               : Knowledge_Base;
   Filters            : Compiler_Lists.List;
   Load_Standard_Base : Boolean := True;
   Batch              : Boolean := False;
   Show_Targets       : Boolean := False;
   Show_Compilers     : Boolean := False;

   Compilers : Compiler_Lists.List;
   package Compiler_Sort is
     new Compiler_Lists.Generic_Sorting (Display_Before);

   Valid_Switches : constant String :=
                      "-batch -config= -db: h o: v q -show-targets"
                      & " -validate -mi-show-compilers -target= "
                      & "-fallback-targets";

   --------------
   -- Callback --
   --------------

   procedure Callback
     (Iterator          : in out All_Iterator;
      Base              : in out Knowledge_Base;
      Comp              : Compiler;
      Runtime_Specified : Boolean;
      From_Extra_Dir    : Boolean;
      Continue          : out Boolean)
   is
      New_Comp : Compiler := Comp;
      C        : Compiler_Lists.Cursor;
      Index    : Count_Type := 1;
   begin
      --  Do nothing if a runtime needs to be specified, as this is only for
      --  interactive use.

      if not Runtime_Specified then
         if Iterator.Filter_Matched /=
           (Iterator.Filter_Matched'Range => True)
         then
            C := First (Iterator.Filters);
            while Has_Element (C) loop
               if not Iterator.Filter_Matched (Index)
                 and then Filter_Match
                   (Base, Comp => Comp, Filter => Element (C).all)
               then
                  Set_Selection (New_Comp, True);
                  Iterator.Filter_Matched (Index) := True;
                  exit;
               end if;

               Index := Index + 1;
               Next (C);
            end loop;
         end if;

         --  Ignore compilers from extra directories, unless they have been
         --  selected because of a --config argument

         if Is_Selected (New_Comp) or else not From_Extra_Dir then
            Put_Verbose
              ("Adding compiler to interactive menu "
               & To_String (Base, Comp, True)
               & " selected=" & Is_Selected (New_Comp)'Img);
            Append (Iterator.Compilers, new Compiler'(New_Comp));
         end if;
      end if;

      Continue := True;
   end Callback;

   ----------
   -- Help --
   ----------

   procedure Help (Base : Knowledge_Base) is
      Known : Unbounded_String;
   begin
      Known_Compiler_Names (Base, Known);
      Usage;
      Put_Line ("            The known compilers are: " & To_String (Known));
   end Help;

   ----------------------------------
   -- Display_Compilers_For_Parser --
   ----------------------------------

   procedure Display_Compilers_For_Parser
     (Base      : in out Knowledge_Base;
      Compilers : in out Compiler_Lists.List)
   is
      Comp    : Compiler_Lists.Cursor := First (Compilers);

      Count   : constant Integer := Integer (Length (Compilers));
      Choices : array (1 .. Count) of Compiler_Lists.Cursor;

   begin
      for C in Choices'Range loop
         Choices (C) := Comp;
         Next (Comp);
      end loop;

      Filter_Compilers_List (Base, Compilers, Selected_Targets_Set);

      Put
        (To_String
           (Base,
            Compilers,
            Selected_Only   => False,
            Show_Target     => True,
            Parser_Friendly => True));
   end Display_Compilers_For_Parser;

   ------------------------------------
   -- Select_Compilers_Interactively --
   ------------------------------------

   procedure Select_Compilers_Interactively
     (Base      : in out Knowledge_Base;
      Compilers : in out Compiler_Lists.List)
   is
      Comp   : Compiler_Lists.Cursor := First (Compilers);
      Tmp    : Natural;
      Choice : Natural;
      Line   : String (1 .. 1024);

      Count   : constant Integer := Integer (Length (Compilers));
      Choices : array (1 .. Count) of Compiler_Lists.Cursor;

   begin
      for C in Choices'Range loop
         Choices (C) := Comp;
         Next (Comp);
      end loop;

      loop
         Filter_Compilers_List (Base, Compilers, Selected_Targets_Set);

         Put_Line ("--------------------------------------------------");
         Put_Line
           ("gprconfig has found the following compilers on your PATH.");
         Put_Line
           ("Only those matching the target and the selected compilers"
            & " are displayed.");

         Put (To_String
              (Base, Compilers, Selected_Only => False,
               Show_Target => Selected_Targets_Set = All_Target_Sets));

         Put
           ("Select or unselect the following compiler (or ""s"" to save): ");
         Get_Line (Line, Tmp);

         exit when Tmp = 1 and then Line (1) = 's';

         if Tmp = 0 then
            Choice := 0;

         else
            begin
               Choice := Natural'Value (Line (1 .. Tmp));

               if Choice > Choices'Last then
                  Choice := 0;
               end if;

            exception
               when Constraint_Error =>
                  Choice := 0;
            end;
         end if;

         if Choice = 0 then
            Put_Line ("Unrecognized choice");

         else
            Set_Selection
              (Compilers, Choices (Choice),
               not Is_Selected (Element (Choices (Choice)).all));
         end if;
      end loop;
   end Select_Compilers_Interactively;

   ------------------------------
   -- Show_Command_Line_Config --
   ------------------------------

   procedure Show_Command_Line_Config (Compilers : Compiler_Lists.List) is
      C : Compiler_Lists.Cursor;
   begin
      if not Is_Empty (Compilers) then
         New_Line;
         Put_Line ("You can regenerate the same config file in batch mode");
         Put_Line (" with the following command line:");
         Put ("gprconfig --batch");
         Put (" --target=");
         if Selected_Target = Null_Unbounded_String then
            Put ("all");
         else
            Put (To_String (Selected_Target));
         end if;

         C := First (Compilers);
         while Has_Element (C) loop
            if Is_Selected (Element (C).all) then
               Put (" --config="
                    & To_String
                      (Base, Element (C).all, As_Config_Arg => True));
            end if;
            Next (C);
         end loop;
         New_Line;
         New_Line;
      end if;
   end Show_Command_Line_Config;

   -----------
   -- Usage --
   -----------

   procedure Usage is
   begin
      Util.Display_Usage_Version_And_Help;
      Put_Line (" --target=target (" & Sdefault.Hostname & " by default)");
      Put_Line
        ("            Select specified target or ""all"" for any target.");
      Put_Line (" --show-targets : List all compiler targets available.");
      Put_Line (" --mi-show-compilers : List all compilers available in a " &
                "parser-friendly way.");
      Put_Line (" --batch  : batch mode, no interactive compiler selection.");
      Put_Line (" -v       : verbose mode.");
      Put_Line (" -q       : quiet output.");
      Put_Line (" -o file  : Name and directory of the output file.");
      Put_Line ("            default is " & GPR.Util.Default_Config_Name);
      Put_Line (" --db dir : Parse dir as an additional knowledge base.");
      Put_Line (" --db-    : Do not load the standard knowledge base from:");
      Put_Line ("   " & Default_Knowledge_Base_Directory);
      Put_Line (" --validate : Validate the contents of the knowledge base");
      Put_Line ("            before loading.");
      Put_Line (" --config=language[,version[,runtime[,path[,name]]]]");
      Put_Line ("            Preselect a compiler.");
      Put_Line ("            Name is either one of the names of the blocks");
      Put_Line ("            in the knowledge base ('GCC', 'GCC-28',...) or");
      Put_Line ("            the base name of an executable ('gcc',");
      Put_Line ("            'gnatmake').");
      Put_Line ("            An empty string can be specified for any of the");
      Put_Line ("            optional parameters");
   end Usage;

begin
   Util.Set_Program_Name ("gprconfig");

   Selected_Target := To_Unbounded_String (Sdefault.Hostname);

   --  First, check if --version or --help is used

   Check_Version_And_Help ("GPRCONFIG", "2006");

   --  Now check whether we should parse the default knownledge base.
   --  This needs to be done first, since that influences --config and -h
   --  at least.

   Initialize_Option_Scan;

   loop
      case Getopt (Valid_Switches) is
         when '-' =>
            if Full_Switch = "-db" then
               if Parameter = "-" then
                  Load_Standard_Base := False;
               end if;

            elsif Full_Switch = "-validate" then
               Opt_Validate := True;

            elsif Full_Switch = "-target" then
               Target_Specified := True;

               if Parameter = "all" then
                  Selected_Target := Null_Unbounded_String;

               else
                  Selected_Target := To_Unbounded_String (Parameter);
                  Output_File := To_Unbounded_String (Parameter & ".cgpr");
               end if;

            elsif Full_Switch = "-show-targets" then
               --  By default, display all targets available
               Selected_Target := Null_Unbounded_String;

            elsif Full_Switch = "-fallback-targets" then
               Native_Target := True;
            end if;

         when 'q' =>
            Opt.Quiet_Output := True;
            Current_Verbosity := Default;

         when 'v' =>
            case Current_Verbosity is
               when Default => Current_Verbosity := Medium;
               when others  => Current_Verbosity := High;
            end case;

            Opt.Quiet_Output := False;

         when ASCII.NUL =>
            exit;
         when others =>
            null;
      end case;
   end loop;

   if Selected_Target = Null_Unbounded_String then
      --  Fallback targets do not make sense in context of --target=all.
      Native_Target := False;
   end if;

   Pedantic_KB := True;

   if Load_Standard_Base then
      Parse_Knowledge_Base
        (Base, Default_Knowledge_Base_Directory, Validate => Opt_Validate);
   end if;

   --  Now check all the other command line switches

   Initialize_Option_Scan;

   loop
      case Getopt (Valid_Switches) is
         when '-' =>
            if Full_Switch = "-config" then
               declare
                  Requires_Comp : Boolean;
                  Comp          : Compiler_Access;
               begin
                  Parse_Config_Parameter
                    (Base              => Base,
                     Config            => Parameter,
                     Compiler          => Comp,
                     Requires_Compiler => Requires_Comp);
                  if Requires_Comp then
                     Append (Filters, Comp);
                  else
                     Append (Compilers, Comp);
                  end if;
               end;

            elsif Full_Switch = "-batch" then
               Batch := True;

            elsif Full_Switch = "-mi-show-compilers" then
               Show_Compilers := True;

            elsif Full_Switch = "-show-targets" then
               Show_Targets := True;

            elsif Full_Switch = "-db" then
               if Parameter = "-" then
                  null;  --  already processed
               else
                  Parse_Knowledge_Base
                    (Base, Parameter, Validate => Opt_Validate);
               end if;
            end if;

         when 'h' =>
            Help (Base);
            return;

         when 'o' =>
            Output_File := To_Unbounded_String (Parameter);

         when 'q' | 'v' | 't' =>
            null;   --  already processed

         when others =>
            exit;
      end case;
   end loop;

   Put_Verbose ("Only compilers matching target "
                & To_String (Selected_Target)
                & " will be preserved");
   Get_Targets_Set
     (Base, To_String (Selected_Target), Selected_Targets_Set);

   if Batch then
      Complete_Command_Line_Compilers
        (Base,
         Selected_Targets_Set,
         Filters,
         Compilers,
         Target_Specified,
         Selected_Target);

      --  Selected target may have changed due to fallback, need to update
      --  corresponding target set.
      Get_Targets_Set
        (Base, To_String (Selected_Target), Selected_Targets_Set);
   else
      declare
         Iter : All_Iterator (Length (Filters));
      begin
         Iter.Filters := Filters;
         Foreach_Compiler_In_Path
           (Iterator   => Iter,
            Base       => Base,
            On_Target  => Selected_Targets_Set,
            Extra_Dirs => Extra_Dirs_From_Filters (Filters));

         Splice (Target => Compilers,
                 Before => No_Element,
                 Source => Iter.Compilers);
      end;

      if Show_Targets or else Current_Verbosity /= Default then
         declare
            use String_Lists;
            All_Target : String_Lists.List;
            C          : Compiler_Lists.Cursor := First (Compilers);
         begin
            Put_Line ("List of targets supported by a compiler:");
            while Has_Element (C) loop
               if Target (Element (C).all) /= No_Name then
                  declare
                     Cur_Target : constant String :=
                                    Get_Name_String (Target (Element (C).all));
                     T          : String_Lists.Cursor := First (All_Target);
                     Dup        : Boolean := False;

                     TS_Id      : Targets_Set_Id;
                  begin
                     while Has_Element (T) loop
                        if Element (T) = Cur_Target then
                           Dup := True;
                           exit;
                        end if;
                        Next (T);
                     end loop;

                     if not Dup then
                        Get_Targets_Set (Base, Cur_Target, TS_Id);
                        Put (Normalized_Target (Base, TS_Id));
                        if Cur_Target = Sdefault.Hostname then
                           Put (" (native target)");
                        end if;
                        New_Line;
                        Append (All_Target, Cur_Target);
                     end if;
                  end;
               end if;
               Next (C);
            end loop;
         end;
         if Show_Targets then
            return;
         end if;
      end if;

      if Is_Empty (Compilers) then
         if Selected_Target /= Null_Unbounded_String then
            Put_Line
              (Standard_Error,
               "No compilers found for target " & To_String (Selected_Target));
         else
            Put_Line (Standard_Error, "No compilers found");
         end if;
         Ada.Command_Line.Set_Exit_Status (1);
         return;
      end if;

      Compiler_Sort.Sort (Compilers);

      if Show_Compilers then
         Display_Compilers_For_Parser (Base, Compilers);
         return;
      else
         Select_Compilers_Interactively (Base, Compilers);
         Show_Command_Line_Config (Compilers);
      end if;
   end if;

   if not Target_Specified then
      Get_Targets_Set
        (Base, GPR.Sdefault.Hostname, Selected_Targets_Set);
      Selected_Target :=
        To_Unbounded_String (Normalized_Target (Base, Selected_Targets_Set));
   end if;

   if Output_File /= Null_Unbounded_String then

      --  Look for runtime directories XML files

      declare
         Cursor : Compiler_Lists.Cursor;
         Comp   : Compiler_Access;

      begin
         Cursor := Compiler_Lists.First (Compilers);

         while Compiler_Lists.Has_Element (Cursor) loop
            Comp := Compiler_Lists.Element (Cursor);

            if Is_Selected (Comp.all) and then
              Runtime_Dir_Of (Comp) /= No_Name
            then
               declare
                  RTS : constant String :=
                          Get_Name_String (Runtime_Dir_Of (Comp));
                  Last : Natural := RTS'Last;
               begin
                  if RTS (Last) in '/' | Directory_Separator then
                     Last := Last - 1;
                  end if;

                  if Last - RTS'First > 6 and then
                    RTS (Last - 5 .. Last) = "adalib" and then
                    (RTS (Last - 6) = Directory_Separator or else
                     (RTS (Last - 6) = '/'))

                  then
                     Last := Last - 6;
                  else
                     Last := RTS'Last;
                  end if;

                  Parse_Knowledge_Base (Base, RTS (RTS'First .. Last));
               end;
            end if;

            Compiler_Lists.Next (Cursor);
         end loop;
      end;

      Generate_Configuration
        (Base,
         Compilers,
         To_String (Output_File),
         To_String (Selected_Target),
         Selected_Targets_Set);
   end if;

exception
   when Invalid_Config =>
      Put_Line
        (Standard_Error, "Invalid configuration specified with --config");
      Ada.Command_Line.Set_Exit_Status (1);
   when Generate_Error =>
      Put_Line
        (Standard_Error, "Generation of configuration files failed");
      Ada.Command_Line.Set_Exit_Status (3);
   when E : Knowledge_Base_Validation_Error =>
      Put_Verbose (Exception_Information (E));
      Ada.Command_Line.Set_Exit_Status (4);
   when E : Invalid_Knowledge_Base =>
      Put_Line
        (Standard_Error, "Invalid setup of the gprconfig knowledge base");
      Put_Verbose (Exception_Information (E));
      Ada.Command_Line.Set_Exit_Status (4);
   when End_Error =>
      null;
   when Invalid_Switch =>
      Put_Line
        (Standard_Error, "Invalid command line switch: -" & Full_Switch);
      Try_Help;
      Ada.Command_Line.Set_Exit_Status (2);
   when Invalid_Parameter =>
      Put_Line
        (Standard_Error, "Missing parameter for switch: -" & Full_Switch);
      Try_Help;
      Ada.Command_Line.Set_Exit_Status (2);
end GprConfig.Main;
