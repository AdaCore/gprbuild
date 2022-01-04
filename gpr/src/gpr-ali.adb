------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 1992-2022, Free Software Foundation, Inc.         --
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

with Ada.Strings.Fixed; use Ada.Strings.Fixed;

with GPR.Names;  use GPR.Names;
with GPR.Output; use GPR.Output;
with GPR.Opt;

package body GPR.ALI is

   use ASCII;
   --  Make control characters visible

   --  The following array records which characters currently are used as line
   --  type markers in the ALI file. This is used in Scan_ALI to detect (or
   --  skip) invalid lines.

   Known_ALI_Lines : constant array (Character range 'A' .. 'Z') of Boolean :=
     ('V'    => True,   -- version
      'M'    => True,   -- main program
      'A'    => True,   -- argument
      'P'    => True,   -- program
      'R'    => True,   -- restriction
      'I'    => True,   -- interrupt
      'U'    => True,   -- unit
      'W'    => True,   -- with
      'L'    => True,   -- linker option
      'N'    => True,   -- notes
      'E'    => True,   -- external
      'D'    => True,   -- dependency
      'X'    => True,   -- xref
      'S'    => True,   -- specific dispatching
      'Y'    => True,   -- limited_with
      'Z'    => True,   -- implicit with from instantiation
      'C'    => True,   -- SCO information
      'F'    => True,   -- SPARK cross-reference information
      others => False);

   Spark_End_Marker : constant Text_Buffer := "GG EK_END_MARKER";

   --------------------
   -- Initialize_ALI --
   --------------------

   procedure Initialize_ALI is
   begin
      --  When (re)initializing ALI data structures the ALI user expects to
      --  get a fresh set of data structures. Thus we first need to erase the
      --  marks put in the name table by the previous set of ALI routine calls.
      --  These two loops are empty and harmless the first time in.

      for J in ALIs.First .. ALIs.Last loop
         Set_Name_Table_Int (ALIs.Table (J).Afile, 0);
      end loop;

      for J in Units.First .. Units.Last loop
         Set_Name_Table_Int (Units.Table (J).Uname, 0);
      end loop;

      --  Free argument table strings

      for J in Args.First .. Args.Last loop
         Free (Args.Table (J));
      end loop;

      --  Initialize all tables

      ALIs.Init;
      --  No_Deps.Init;
      Units.Init;
      Withs.Init;
      Sdep.Init;
      --  Linker_Options.Init;
      --  Notes.Init;
      --  Xref_Section.Init;
      --  Xref_Entity.Init;
      --  Xref.Init;
      --  Version_Ref.Reset;

      --  Add dummy zero'th item in Linker_Options and Notes for sort calls

      --  Linker_Options.Increment_Last;
      --  Notes.Increment_Last;

      --  Initialize global variables recording cumulative options in all
      --  ALI files that are read for a given processing run in gnatbind.

   end Initialize_ALI;

   --------------
   -- Scan_ALI --
   --------------

   function Scan_ALI
     (F           : File_Name_Type;
      T           : Text_Buffer_Ptr;
      Ignore_ED   : Boolean;
      Err         : Boolean;
      Read_Lines  : String;
      Object_Path : File_Name_Type := No_File) return ALI_Id
   is
      P         : Text_Ptr    := T'First;
      Line      : Line_Number := 1;
      Id        : ALI_Id;
      C         : Character;
      First_Arg : Arg_Id;
      First_P   : Text_Ptr    := T'First;
      Last_P    : Text_Ptr    := T'First;

      Ignore : array (Character range 'A' .. 'Z') of Boolean;
      --  Ignore (X) is set to True if lines starting with X are to
      --  be ignored by Scan_ALI and skipped, and False if the lines
      --  are to be read and processed.

      function At_Eol return Boolean;
      --  Test if at end of line

      function At_End_Of_Field return Boolean;
      --  Test if at end of line, or if at blank or horizontal tab

      procedure Check_At_End_Of_Field;
      --  Check if we are at end of field, fatal error if not

      procedure Checkc (C : Character);
      --  Check next character is C. If so bump past it, if not fatal error

      procedure Check_Unknown_Line;
      --  If Ignore_Errors mode, then checks C to make sure that it is not
      --  an unknown ALI line type characters, and if so, skips lines
      --  until the first character of the line is one of these characters,
      --  at which point it does a Getc to put that character in C. The
      --  call has no effect if C is already an appropriate character.
      --  If not in Ignore_Errors mode, a fatal error is signalled if the
      --  line is unknown. Note that if C is an EOL on entry, the line is
      --  skipped (it is assumed that blank lines are never significant).
      --  If C is EOF on entry, the call has no effect (it is assumed that
      --  the caller will properly handle this case).

      function Getc return Character;
      --  Get next character, bumping P past the character obtained

      function Get_File_Name
        (Lower         : Boolean := False;
         May_Be_Quoted : Boolean := False) return File_Name_Type;
      --  Skip blanks, then scan out a file name (name is left in Name_Buffer
      --  with length in Name_Len, as well as returning a File_Name_Type value.
      --  If May_Be_Quoted is True and the first non blank character is '"',
      --  then remove starting and ending quotes and undoubled internal quotes.
      --  If lower is false, the case is unchanged, if Lower is True then the
      --  result is forced to all lower case for systems where file names are
      --  not case sensitive. This ensures that gnatbind works correctly
      --  regardless of the case of the file name on all systems. The scan
      --  is terminated by a end of line, space or horizontal tab. Any other
      --  special characters are included in the returned name.

      function Get_Name
        (Ignore_Spaces  : Boolean := False;
         Ignore_Special : Boolean := False;
         May_Be_Quoted  : Boolean := False) return Name_Id;
      --  Skip blanks, then scan out a name (name is left in Name_Buffer with
      --  length in Name_Len, as well as being returned in Name_Id form).
      --  If Lower is set to True then the Name_Buffer will be converted to
      --  all lower case, for systems where file names are not case sensitive.
      --  This ensures that gnatbind works correctly regardless of the case
      --  of the file name on all systems. The termination condition depends
      --  on the settings of Ignore_Spaces and Ignore_Special:
      --
      --    If Ignore_Spaces is False (normal case), then scan is terminated
      --    by the normal end of field condition (EOL, space, horizontal tab)
      --
      --    If Ignore_Special is False (normal case), the scan is terminated by
      --    a typeref bracket or an equal sign except for the special case of
      --    an operator name starting with a double quote which is terminated
      --    by another double quote.
      --
      --    If May_Be_Quoted is True and the first non blank character is '"'
      --    the name is 'unquoted'. In this case Ignore_Special is ignored and
      --    assumed to be True.
      --
      --  It is an error to set both Ignore_Spaces and Ignore_Special to True.
      --  This function handles wide characters properly.

      function Get_Nat return Nat;
      --  Skip blanks, then scan out an unsigned integer value in Nat range
      --  raises ALI_Reading_Error if the encoutered type is not natural.

      function Get_Stamp return Time_Stamp_Type;
      --  Skip blanks, then scan out a time stamp

      function Get_Unit_Name return Unit_Name_Type;
      --  Skip blanks, then scan out a file name (name is left in Name_Buffer
      --  with length in Name_Len, as well as returning a Unit_Name_Type value.
      --  The case is unchanged and terminated by a normal end of field.

      function Nextc return Character;
      --  Return current character without modifying pointer P

--        procedure Get_Typeref
--          (Current_File_Num : Sdep_Id;
--           Ref             : out Tref_Kind;
--           File_Num        : out Sdep_Id;
--           Line            : out Nat;
--           Ref_Type        : out Character;
--           Col             : out Nat;
--           Standard_Entity : out Name_Id);
      --  Parse the definition of a typeref (<...>, {...} or (...))

      procedure Skip_Eol;
      --  Skip past spaces, then skip past end of line (fatal error if not
      --  at end of line). Also skips past any following blank lines.

      procedure Skip_Next_Line;
      --  Skip rest of current line and any following blank lines

      procedure Skip_Space;
      --  Skip past white space (blanks or horizontal tab)

      ---------------------
      -- At_End_Of_Field --
      ---------------------

      function At_End_Of_Field return Boolean is
      begin
         return Nextc <= ' ';
      end At_End_Of_Field;

      ------------
      -- At_Eol --
      ------------

      function At_Eol return Boolean is
      begin
         return Nextc = EOF or else Nextc = CR or else Nextc = LF;
      end At_Eol;

      ---------------------------
      -- Check_At_End_Of_Field --
      ---------------------------

      procedure Check_At_End_Of_Field is
      begin
         if not At_End_Of_Field then
            while Nextc > ' ' loop
               P := P + 1;
            end loop;
         end if;
      end Check_At_End_Of_Field;

      ------------------------
      -- Check_Unknown_Line --
      ------------------------

      procedure Check_Unknown_Line is
      begin
         while C not in 'A' .. 'Z'
           or else not Known_ALI_Lines (C)
         loop
            if C = CR or else C = LF then
               Skip_Next_Line;
               C := Nextc;

            elsif C = EOF then
               return;

            else
               Skip_Next_Line;
               C := Getc;
            end if;
         end loop;
      end Check_Unknown_Line;

      ------------
      -- Checkc --
      ------------

      procedure Checkc (C : Character) is
         pragma Unreferenced (C);
      begin
         P := P + 1;
      end Checkc;

      -------------------
      -- Get_File_Name --
      -------------------

      function Get_File_Name
        (Lower         : Boolean := False;
         May_Be_Quoted : Boolean := False) return File_Name_Type
      is
         F : Name_Id;

      begin
         F := Get_Name (Ignore_Special => True,
                        May_Be_Quoted  => May_Be_Quoted);

         --  Convert file name to all lower case if file names are not case
         --  sensitive. This ensures that we handle names in the canonical
         --  lower case format, regardless of the actual case.

         if Lower and not File_Names_Case_Sensitive then
            Canonical_Case_File_Name (Name_Buffer (1 .. Name_Len));
            return Name_Find;
         else
            return File_Name_Type (F);
         end if;
      end Get_File_Name;

      --------------
      -- Get_Name --
      --------------

      function Get_Name
        (Ignore_Spaces  : Boolean := False;
         Ignore_Special : Boolean := False;
         May_Be_Quoted  : Boolean := False) return Name_Id
      is
         Char : Character;

      begin
         Name_Len := 0;
         Skip_Space;

         if At_Eol then
            return Error_Name;
         end if;

         Char := Getc;

         --  Deal with quoted characters

         if May_Be_Quoted and then Char = '"' then
            loop
               if At_Eol then
                  return Error_Name;
               end if;

               Char := Getc;

               if Char = '"' then
                  if At_Eol then
                     exit;

                  else
                     Char := Getc;

                     if Char /= '"' then
                        P := P - 1;
                        exit;
                     end if;
                  end if;
               end if;

               Add_Char_To_Name_Buffer (Char);
            end loop;

         --  Other than case of quoted character

         else
            P := P - 1;
            loop
               Add_Char_To_Name_Buffer (Getc);

               exit when At_End_Of_Field and then not Ignore_Spaces;

               if not Ignore_Special then
                  if Name_Buffer (1) = '"' then
                     exit when Name_Len > 1
                               and then Name_Buffer (Name_Len) = '"';

                  else
                     --  Terminate on parens or angle brackets or equal sign

                     exit when Nextc = '(' or else Nextc = ')'
                       or else Nextc = '{' or else Nextc = '}'
                       or else Nextc = '<' or else Nextc = '>'
                       or else Nextc = '=';

                     --  Terminate on comma

                     exit when Nextc = ',';

                     --  Terminate if left bracket not part of wide char
                     --  sequence Note that we only recognize brackets
                     --  notation so far ???

                     exit when Nextc = '[' and then T (P + 1) /= '"';

                     --  Terminate if right bracket not part of wide char
                     --  sequence.

                     exit when Nextc = ']' and then T (P - 1) /= '"';
                  end if;
               end if;
            end loop;
         end if;

         return Name_Find;
      end Get_Name;

      -------------------
      -- Get_Unit_Name --
      -------------------

      function Get_Unit_Name return Unit_Name_Type is
      begin
         return Unit_Name_Type (Get_Name);
      end Get_Unit_Name;

      -------------
      -- Get_Nat --
      -------------

      function Get_Nat return Nat is
         V : Nat;

      begin
         Skip_Space;

         --  Check if we are on a number. In the case of bad ALI files, this
         --  may not be true.

         if not (Nextc in '0' .. '9') then
            return 0;
         end if;

         V := 0;
         loop
            V := V * 10 + (Character'Pos (Getc) - Character'Pos ('0'));

            exit when At_End_Of_Field;
            exit when Nextc < '0' or else Nextc > '9';
         end loop;

         return V;
      end Get_Nat;

      ---------------
      -- Get_Stamp --
      ---------------

      function Get_Stamp return Time_Stamp_Type is
         T     : Time_Stamp_Type;
         Start : Integer;

      begin
         Skip_Space;

         if At_Eol then
            return Dummy_Time_Stamp;
         end if;

         --  Following reads old style time stamp missing first two digits

         if Nextc in '7' .. '9' then
            T (1) := '1';
            T (2) := '9';
            Start := 3;

         --  Normal case of full year in time stamp

         else
            Start := 1;
         end if;

         for J in Start .. T'Last loop
            T (J) := Getc;
         end loop;

         return T;
      end Get_Stamp;

      -----------------
      -- Get_Typeref --
      -----------------

--        procedure Get_Typeref
--          (Current_File_Num : Sdep_Id;
--           Ref              : out Tref_Kind;
--           File_Num         : out Sdep_Id;
--           Line             : out Nat;
--           Ref_Type         : out Character;
--           Col              : out Nat;
--           Standard_Entity  : out Name_Id)
--        is
--           N : Nat;
--        begin
--           case Nextc is
--              when '<'    => Ref := Tref_Derived;
--              when '('    => Ref := Tref_Access;
--              when '{'    => Ref := Tref_Type;
--              when others => Ref := Tref_None;
--           end case;
--
--           --  Case of typeref field present
--
--           if Ref /= Tref_None then
--              P := P + 1; -- skip opening bracket
--
--              if Nextc in 'a' .. 'z' then
--                 File_Num        := No_Sdep_Id;
--                 Line            := 0;
--                 Ref_Type        := ' ';
--                 Col             := 0;
--                 Standard_Entity := Get_Name (Ignore_Spaces => True);
--              else
--                 N := Get_Nat;
--
--                 if Nextc = '|' then
--                    File_Num := Sdep_Id (N + Nat (First_Sdep_Entry) - 1);
--                    P := P + 1;
--                    N := Get_Nat;
--                 else
--                    File_Num := Current_File_Num;
--                 end if;
--
--                 Line            := N;
--                 Ref_Type        := Getc;
--                 Col             := Get_Nat;
--                 Standard_Entity := No_Name;
--              end if;
--
--              --  ??? Temporary workaround for nested generics case:
--              --     4i4 Directories{1|4I9[4|6[3|3]]}
--              --  See C918-002
--
--              declare
--                 Nested_Brackets : Natural := 0;
--
--              begin
--                 loop
--                    case Nextc is
--                       when '['   =>
--                          Nested_Brackets := Nested_Brackets + 1;
--                       when ']' =>
--                          Nested_Brackets := Nested_Brackets - 1;
--                       when others =>
--                          if Nested_Brackets = 0 then
--                             exit;
--                          end if;
--                    end case;
--
--                    Skipc;
--                 end loop;
--              end;
--
--              P := P + 1; -- skip closing bracket
--              Skip_Space;
--
--           --  No typeref entry present
--
--           else
--              File_Num        := No_Sdep_Id;
--              Line            := 0;
--              Ref_Type        := ' ';
--              Col             := 0;
--              Standard_Entity := No_Name;
--           end if;
--        end Get_Typeref;

      ----------
      -- Getc --
      ----------

      function Getc return Character is
      begin
         if P = T'Last then
            return EOF;
         else
            P := P + 1;
            return T (P - 1);
         end if;
      end Getc;

      -----------
      -- Nextc --
      -----------

      function Nextc return Character is
      begin
         return T (P);
      end Nextc;

      --------------
      -- Skip_Eol --
      --------------

      procedure Skip_Eol is
      begin
         Skip_Space;

         if not At_Eol then
            while not At_Eol loop
               P := P + 1;
            end loop;
         end if;

         --  Loop to skip past blank lines (first time through skips this EOL)

         while Nextc < ' ' and then Nextc /= EOF loop
            if Nextc = LF then
               Line := Line + 1;
            end if;

            P := P + 1;
         end loop;
      end Skip_Eol;

      ---------------
      -- Skip_Next_Line --
      ---------------

      procedure Skip_Next_Line is
      begin
         First_P := P;

         while not At_Eol loop
            P := P + 1;
         end loop;

         Last_P := P - 1;

         Skip_Eol;
      end Skip_Next_Line;

      ----------------
      -- Skip_Space --
      ----------------

      procedure Skip_Space is
      begin
         while Nextc = ' ' or else Nextc = HT loop
            P := P + 1;
         end loop;
      end Skip_Space;

   --  Start of processing for Scan_ALI

   begin
--        --  Return the ALI_Id if already in the ALIs table
--
--        for J in 1 .. ALIs.Last loop
--           if F = ALIs.Table (J).Afile then
--              return J;
--           end if;
--        end loop;

      First_Sdep_Entry := Sdep.Last + 1;

      --  Acquire lines to be read

      Ignore := ('U' => False, others => True);

      for J in Read_Lines'Range loop
         Ignore (Read_Lines (J)) := False;
      end loop;

      --  Setup ALI Table entry with appropriate defaults

      ALIs.Increment_Last;
      Id := ALIs.Last;
      Set_Name_Table_Int (F, Int (Id));

      ALIs.Table (Id) :=
        (Afile                        => F,
         Compile_Errors               => False,
         First_Sdep                   => No_Sdep_Id,
         First_Unit                   => No_Unit_Id,
         Last_Sdep                    => No_Sdep_Id,
         Last_Unit                    => No_Unit_Id,
         Locking_Policy               => ' ',
         Main_Priority                => -1,
         Main_CPU                     => -1,
         GNAT_Version                 => No_Name,
         Main_Program                 => None,
         No_Object                    => False,
         Normalize_Scalars            => False,
         Ofile_Full_Name              => Object_Path,
         Partition_Elaboration_Policy => ' ',
         Queuing_Policy               => ' ',
         SAL_Interface                => False,
         Sfile                        => No_File,
         SSO_Default                  => ' ',
         Task_Dispatching_Policy      => ' ',
         Time_Slice_Value             => -1,
         WC_Encoding                  => 'b',
         Unit_Exception_Table         => False,
         Zero_Cost_Exceptions         => False,
         Restrictions                 => No_Restrictions);

      --  Now we acquire the input lines from the ALI file. Note that the
      --  convention in the following code is that as we enter each section,
      --  C is set to contain the first character of the following line.

      C := Getc;

      Check_Unknown_Line;

      --  Acquire library version

      if C /= 'V' then

         --  The V line missing really indicates trouble, most likely it
         --  means we don't have an ALI file at all, so here we give a
         --  fatal error even if we are in Ignore_Errors mode.

         return No_ALI_Id;

      else
         Checkc (' ');
         Checkc ('"');
         Name_Len := 0;
         while not At_Eol and not (Nextc = '"') loop
            Add_Char_To_Name_Buffer (Getc);
         end loop;

         --  Check that we exited on a closing double quote
         if Nextc /= '"' then
            return No_ALI_Id;
         end if;

         --  Check length compatibility
         if Name_Len > GNAT_Version_Max_Len then
            return No_ALI_Id;
         end if;

         --  ??? Duplicate code from:
         --    GPR.Nmsc.Check_Configuration.
         --    Process_Project_Level_Array_Attributes

         declare
            Raw : String (1 .. GNAT_Version_Max_Len);
            Last : constant Natural := Name_Len;
            Start : Natural;
         begin
            Raw (1 .. Last) := Name_Buffer (1 .. Last);
            Start := Index (Name_Buffer (1 .. Last), " v");

            if Start /= 0 then
               Set_Name_Buffer (GNAT_And_Space);
               Add_Str_To_Name_Buffer
                 (Raw (Start + 2 .. Last));
               ALIs.Table (Id).GNAT_Version := Name_Find;
            end if;
         end;

         Skip_Eol;
      end if;

      C := Getc;
      Check_Unknown_Line;

      --  Acquire main program line if present

      if C = 'M' then
         Checkc (' ');
         Skip_Space;

         C := Getc;

         if C = 'F' then
            ALIs.Table (Id).Main_Program := Func;
         elsif C = 'P' then
            ALIs.Table (Id).Main_Program := Proc;
         end if;

         Skip_Next_Line;
         C := Getc;
      end if;

      --  Acquire argument lines

      First_Arg := Args.Last + 1;

      A_Loop : loop
         Check_Unknown_Line;
         exit A_Loop when C /= 'A';

         if Ignore ('A') then
            Skip_Next_Line;

         else
            Checkc (' ');

            --  Scan out argument

            Name_Len := 0;
            while not At_Eol loop
               Add_Char_To_Name_Buffer (Getc);
            end loop;

            --  If -fstack-check, record that it occurred. Note that an
            --  additional string parameter can be specified, in the form of
            --  -fstack-check={no|generic|specific}. "no" means no checking,
            --  "generic" means force the use of old-style checking, and
            --  "specific" means use the best checking method.

            if Name_Len >= 13
              and then Name_Buffer (1 .. 13) = "-fstack-check"
              and then Name_Buffer (1 .. Name_Len) /= "-fstack-check=no"
            then
               Stack_Check_Switch_Set := True;
            end if;

            --  Store the argument

            Args.Increment_Last;
            Args.Table (Args.Last) := new String'(Name_Buffer (1 .. Name_Len));

            Skip_Eol;
         end if;

         C := Getc;
      end loop A_Loop;

      --  Acquire P line

      Check_Unknown_Line;

      while C /= 'P' loop
         if C = EOF then
            return No_ALI_Id;
         else
            Skip_Next_Line;
            C := Nextc;
         end if;
      end loop;

      Skip_Next_Line;

      C := Getc;
      Check_Unknown_Line;

      --  Loop to skip to first restrictions line

      while C /= 'R' loop
         if C = EOF then
            return No_ALI_Id;
         else
            Skip_Next_Line;
            C := Nextc;
         end if;
      end loop;

      --  Ignore all 'R' lines

      while C = 'R' loop
         Skip_Next_Line;
         C := Getc;
      end loop;

      --  Acquire 'I' lines if present

      Check_Unknown_Line;

      while C = 'I' loop
         Skip_Next_Line;
         C := Getc;
      end loop;

      --  Acquire 'S' lines if present

      Check_Unknown_Line;

      while C = 'S' loop
         Skip_Next_Line;
         C := Getc;
      end loop;

      --  Loop to acquire unit entries

      U_Loop : loop
         Check_Unknown_Line;
         exit U_Loop when C /= 'U';

         --  Note: as per spec, we never ignore U lines

         Checkc (' ');
         Skip_Space;
         Units.Increment_Last;

         if ALIs.Table (Id).First_Unit = No_Unit_Id then
            ALIs.Table (Id).First_Unit := Units.Last;
         end if;

         declare
            UL : Unit_Record renames Units.Table (Units.Last);

         begin
            UL.Uname                    := Get_Unit_Name;
            UL.Predefined               := False;
            UL.My_ALI                   := Id;
            UL.Sfile                    := Get_File_Name (Lower => True);
            UL.Pure                     := False;
            UL.Preelab                  := False;
            UL.No_Elab                  := False;
            UL.Shared_Passive           := False;
            UL.RCI                      := False;
            UL.Remote_Types             := False;
            UL.Serious_Errors           := False;
            UL.Has_RACW                 := False;
            UL.Init_Scalars             := False;
            UL.Is_Generic               := False;
            UL.Icasing                  := Mixed_Case;
            UL.Kcasing                  := All_Lower_Case;
            UL.Dynamic_Elab             := False;
            UL.Elaborate_Body           := False;
            UL.Set_Elab_Entity          := False;
            UL.Version                  := "00000000";
            UL.First_With               := Withs.Last + 1;
            UL.First_Arg                := First_Arg;
            UL.Elab_Position            := 0;
            UL.SAL_Interface            := ALIs.Table (Id).SAL_Interface;
            UL.Directly_Scanned         := False;
            UL.Body_Needed_For_SAL      := False;
            UL.Elaborate_Body_Desirable := False;
            UL.Optimize_Alignment       := 'O';
            UL.Has_Finalizer            := False;
         end;

         --  Check for duplicated unit in different files

         declare
            Info : constant Int := Get_Name_Table_Int
                                     (Units.Table (Units.Last).Uname);
         begin
            if Info /= 0
              and then Units.Table (Units.Last).Sfile /=
                       Units.Table (Unit_Id (Info)).Sfile
            then
               --  If Err is set then ignore duplicate unit name

               if Err then
                  null;

               --  If Err is not set, then this is a fatal error. This is
               --  the case of being called from the binder, where we must
               --  definitely diagnose this as an error.

               else
                  Set_Standard_Error;
                  Write_Str ("error: duplicate unit name: ");
                  Write_Eol;

                  Write_Str ("error: unit """);
                  Write_Unit_Name (Units.Table (Units.Last).Uname);
                  Write_Str (""" found in file """);
                  Write_Name (Units.Table (Units.Last).Sfile);
                  Write_Char ('"');
                  Write_Eol;

                  Write_Str ("error: unit """);
                  Write_Unit_Name
                    (Units.Table (Unit_Id (Info)).Uname);
                  Write_Str (""" found in file """);
                  Write_Name
                    (Units.Table (Unit_Id (Info)).Sfile);
                  Write_Char ('"');
                  Write_Eol;
                  Set_Standard_Output;

                  return No_ALI_Id;
               end if;
            end if;
         end;

         Set_Name_Table_Int
           (Units.Table (Units.Last).Uname, Int (Units.Last));

         --  Scan out possible version and other parameters

         loop
            Skip_Space;
            exit when At_Eol;
            C := Getc;

            --  Version field

            if C in '0' .. '9' or else C in 'a' .. 'f' then
               Units.Table (Units.Last).Version (1) := C;

               for J in 2 .. 8 loop
                  C := Getc;
                  Units.Table (Units.Last).Version (J) := C;
               end loop;

            --  BD/BN parameters

            elsif C = 'B' then
               C := Getc;

               if C = 'D' then
                  Check_At_End_Of_Field;
                  Units.Table (Units.Last).Elaborate_Body_Desirable := True;

               elsif C = 'N' then
                  Check_At_End_Of_Field;
                  Units.Table (Units.Last).Body_Needed_For_SAL := True;
               end if;

            --  DE parameter (Dynamic elaboration checks)

            elsif C = 'D' then
               C := Getc;

               if C = 'E' then
                  Check_At_End_Of_Field;
                  Units.Table (Units.Last).Dynamic_Elab := True;
               end if;

            --  EB/EE parameters

            elsif C = 'E' then
               C := Getc;

               if C = 'B' then
                  Units.Table (Units.Last).Elaborate_Body := True;
               elsif C = 'E' then
                  Units.Table (Units.Last).Set_Elab_Entity := True;
               end if;

               Check_At_End_Of_Field;

            --  GE parameter (generic)

            elsif C = 'G' then
               C := Getc;

               if C = 'E' then
                  Check_At_End_Of_Field;
                  Units.Table (Units.Last).Is_Generic := True;
               end if;

            --  IL/IS/IU parameters

            elsif C = 'I' then
               C := Getc;

               if C = 'L' then
                  Units.Table (Units.Last).Icasing := All_Lower_Case;
               elsif C = 'S' then
                  Units.Table (Units.Last).Init_Scalars := True;
               elsif C = 'U' then
                  Units.Table (Units.Last).Icasing := All_Upper_Case;
               end if;

               Check_At_End_Of_Field;

            --  KM/KU parameters

            elsif C = 'K' then
               C := Getc;

               if C = 'M' then
                  Units.Table (Units.Last).Kcasing := Mixed_Case;
               elsif C = 'U' then
                  Units.Table (Units.Last).Kcasing := All_Upper_Case;
               end if;

               Check_At_End_Of_Field;

            --  NE parameter

            elsif C = 'N' then
               C := Getc;

               if C = 'E' then
                  Units.Table (Units.Last).No_Elab := True;
                  Check_At_End_Of_Field;
               end if;

            --  PF/PR/PU/PK parameters

            elsif C = 'P' then
               C := Getc;

               if C = 'F' then
                  Units.Table (Units.Last).Has_Finalizer := True;
               elsif C = 'R' then
                  Units.Table (Units.Last).Preelab := True;
               elsif C = 'U' then
                  Units.Table (Units.Last).Pure := True;
               elsif C = 'K' then
                  Units.Table (Units.Last).Unit_Kind := 'p';
               end if;

               Check_At_End_Of_Field;

            --  OL/OO/OS/OT parameters

            elsif C = 'O' then
               C := Getc;

               if C = 'L' or else C = 'O' or else C = 'S' or else C = 'T' then
                  Units.Table (Units.Last).Optimize_Alignment := C;
               end if;

               Check_At_End_Of_Field;

            --  RC/RT parameters

            elsif C = 'R' then
               C := Getc;

               if C = 'C' then
                  Units.Table (Units.Last).RCI := True;
               elsif C = 'T' then
                  Units.Table (Units.Last).Remote_Types := True;
               elsif C = 'A' then
                  Units.Table (Units.Last).Has_RACW := True;
               end if;

               Check_At_End_Of_Field;

            --  SE/SP/SU parameters

            elsif C = 'S' then
               C := Getc;

               if C = 'E' then
                  Units.Table (Units.Last).Serious_Errors := True;
               elsif C = 'P' then
                  Units.Table (Units.Last).Shared_Passive := True;
               elsif C = 'U' then
                  Units.Table (Units.Last).Unit_Kind := 's';
               end if;

               Check_At_End_Of_Field;

            else
               C := Getc;
            end if;
         end loop;

         Skip_Eol;

         C := Getc;

         --  Scan out With lines for this unit

         With_Loop : loop
            Check_Unknown_Line;
            exit With_Loop when C /= 'W' and then C /= 'Y' and then C /= 'Z';

            if Ignore ('W') then
               Skip_Next_Line;

            else
               Checkc (' ');
               Skip_Space;
               Withs.Increment_Last;
               Withs.Table (Withs.Last).Uname              := Get_Unit_Name;
               Withs.Table (Withs.Last).Elaborate          := False;
               Withs.Table (Withs.Last).Elaborate_All      := False;
               Withs.Table (Withs.Last).Elab_Desirable     := False;
               Withs.Table (Withs.Last).Elab_All_Desirable := False;
               Withs.Table (Withs.Last).SAL_Interface      := False;
               Withs.Table (Withs.Last).Limited_With       := (C = 'Y');
               Withs.Table (Withs.Last).Implicit_With_From_Instantiation
                                                           := (C = 'Z');

               --  Generic case with no object file available

               if At_Eol then
                  Withs.Table (Withs.Last).Sfile := No_File;
                  Withs.Table (Withs.Last).Afile := No_File;

               --  Normal case

               else
                  Withs.Table (Withs.Last).Sfile := Get_File_Name
                                                      (Lower => True);
                  Withs.Table (Withs.Last).Afile := Get_File_Name
                                                      (Lower => True);

                  --  Scan out possible E, EA, ED, and AD parameters

                  while not At_Eol loop
                     Skip_Space;

                     if Nextc = 'A' then
                        P := P + 1;
                        Checkc ('D');
                        Check_At_End_Of_Field;

                        --  Store AD indication unless ignore required

                        if not Ignore_ED then
                           Withs.Table (Withs.Last).Elab_All_Desirable :=
                             True;
                        end if;

                     elsif Nextc = 'E' then
                        P := P + 1;

                        if At_End_Of_Field then
                           Withs.Table (Withs.Last).Elaborate := True;

                        elsif Nextc = 'A' then
                           P := P + 1;
                           Check_At_End_Of_Field;
                           Withs.Table (Withs.Last).Elaborate_All := True;

                        else
                           Checkc ('D');
                           Check_At_End_Of_Field;

                           --  Store ED indication unless ignore required

                           if not Ignore_ED then
                              Withs.Table (Withs.Last).Elab_Desirable :=
                                True;
                           end if;
                        end if;

                     else
                        return No_ALI_Id;
                     end if;
                  end loop;
               end if;

               Skip_Eol;
            end if;

            C := Getc;
         end loop With_Loop;

         Units.Table (Units.Last).Last_With := Withs.Last;
         Units.Table (Units.Last).Last_Arg  := Args.Last;

         --  Ignore linker options lines

         Name_Len := 0;

         Linker_Options_Loop : loop
            Check_Unknown_Line;
            exit Linker_Options_Loop when C /= 'L';
            Skip_Next_Line;
            C := Getc;
         end loop Linker_Options_Loop;

         --  Ignore notes lines

         Notes_Loop : loop
            Check_Unknown_Line;
            exit Notes_Loop when C /= 'N';
            Skip_Next_Line;
            C := Getc;
         end loop Notes_Loop;
      end loop U_Loop;

      --  End loop through units for one ALI file

      ALIs.Table (Id).Last_Unit := Units.Last;
      ALIs.Table (Id).Sfile := Units.Table (ALIs.Table (Id).First_Unit).Sfile;

      --  Set types of the units (there can be at most 2 of them)

      if ALIs.Table (Id).First_Unit /= ALIs.Table (Id).Last_Unit then
         Units.Table (ALIs.Table (Id).First_Unit).Utype := Is_Body;
         Units.Table (ALIs.Table (Id).Last_Unit).Utype  := Is_Spec;

      else
         --  Deal with body only and spec only cases, note that the reason we
         --  do our own checking of the name (rather than using Is_Body_Name)
         --  is that Uname drags in far too much compiler junk.

         Get_Name_String (Units.Table (Units.Last).Uname);

         if Name_Buffer (Name_Len) = 'b' then
            Units.Table (Units.Last).Utype := Is_Body_Only;
         else
            Units.Table (Units.Last).Utype := Is_Spec_Only;
         end if;
      end if;

      --  Ignore external version lines

      E_Loop : loop
         Check_Unknown_Line;
         exit E_Loop when C /= 'E';
         Skip_Next_Line;
         C := Getc;
      end loop E_Loop;

      --  Scan out source dependency lines for this ALI file

      ALIs.Table (Id).First_Sdep := Sdep.Last + 1;

      D_Loop : loop
         Check_Unknown_Line;
         exit D_Loop when C /= 'D';

         if Ignore ('D') then
            Skip_Next_Line;

         else
            Checkc (' ');
            Skip_Space;
            Sdep.Increment_Last;

            --  In the following call, Lower is not set to True, this is either
            --  a bug, or it deserves a special comment as to why this is so???

            --  The file/path name may be quoted

            Sdep.Table (Sdep.Last).Sfile :=
              Get_File_Name (May_Be_Quoted => True);

            Sdep.Table (Sdep.Last).Stamp := Get_Stamp;
            Sdep.Table (Sdep.Last).Dummy_Entry :=
              (Sdep.Table (Sdep.Last).Stamp = Dummy_Time_Stamp);

            --  Acquire checksum value

            Skip_Space;

            declare
               Ctr : Natural;
               Chk : Word;

            begin
               Ctr := 0;
               Chk := 0;

               loop
                  exit when At_Eol or else Ctr = 8;

                  if Nextc in '0' .. '9' then
                     Chk := Chk * 16 +
                              Character'Pos (Nextc) - Character'Pos ('0');

                  elsif Nextc in 'a' .. 'f' then
                     Chk := Chk * 16 +
                              Character'Pos (Nextc) - Character'Pos ('a') + 10;

                  else
                     exit;
                  end if;

                  Ctr := Ctr + 1;
                  P := P + 1;
               end loop;

               if Ctr = 8 and then At_End_Of_Field then
                  Sdep.Table (Sdep.Last).Checksum := Chk;
               else
                  return No_ALI_Id;
               end if;
            end;

            --  Acquire (sub)unit and reference file name entries

            Sdep.Table (Sdep.Last).Subunit_Name := No_Name;
            Sdep.Table (Sdep.Last).Unit_Name    := No_Name;
            Sdep.Table (Sdep.Last).Rfile        :=
              Sdep.Table (Sdep.Last).Sfile;
            Sdep.Table (Sdep.Last).Start_Line   := 1;

            if not At_Eol then
               Skip_Space;

               --  Here for (sub)unit name

               if Nextc not in '0' .. '9' then
                  Name_Len := 0;
                  while not At_End_Of_Field loop
                     Add_Char_To_Name_Buffer (Getc);
                  end loop;

                  --  Set the (sub)unit name. Note that we use Name_Find rather
                  --  than Name_Enter here as the subunit name may already
                  --  have been put in the name table by the Project Manager.

                  if Name_Len <= 2
                    or else Name_Buffer (Name_Len - 1) /= '%'
                  then
                     Sdep.Table (Sdep.Last).Subunit_Name := Name_Find;
                  else
                     Name_Len := Name_Len - 2;
                     Sdep.Table (Sdep.Last).Unit_Name := Name_Find;
                  end if;

                  Skip_Space;
               end if;

               --  Here for reference file name entry

               if Nextc in '0' .. '9' then
                  Sdep.Table (Sdep.Last).Start_Line := Get_Nat;
                  Checkc (':');

                  Name_Len := 0;

                  while not At_End_Of_Field loop
                     Add_Char_To_Name_Buffer (Getc);
                  end loop;

                  Sdep.Table (Sdep.Last).Rfile := File_Name_Type (Name_Enter);
               end if;
            end if;

            Skip_Eol;
         end if;

         C := Getc;
      end loop D_Loop;

      ALIs.Table (Id).Last_Sdep := Sdep.Last;

      --  We must at this stage be at an Xref line or the end of file

      if C = EOF then
         --  Check that gnatprove generated .ali files ended with right marker

         if Opt.GnatProve_Mode
           and then T (First_P .. Last_P) /= Spark_End_Marker
         then
            return No_ALI_Id;
         end if;

         return Id;
      end if;

      Check_Unknown_Line;

      if C /= 'X' then
         return No_ALI_Id;
      end if;

      if Opt.GnatProve_Mode then
         --  Check that gnatprove generated .ali files ended with right marker

         while P < T'Last loop
            Skip_Next_Line;
         end loop;

         if T (First_P .. Last_P) /= Spark_End_Marker then
            return No_ALI_Id;
         end if;
      end if;

      return Id;

   exception
      when others =>
         return No_ALI_Id;
   end Scan_ALI;

end GPR.ALI;
