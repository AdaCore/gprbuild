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

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Directories;  use Ada.Directories;

with Ada.Unchecked_Conversion;

with GNAT.Case_Util; use GNAT.Case_Util;

with System.CRTL;
with System.OS_Constants;

with GPR.Names;  use GPR.Names;
with GPR.Output; use GPR.Output;

package body GPR.Osint is

   Current_Full_Lib_Name : File_Name_Type  := No_File;

   function File_Length
     (Name : C_File_Name;
      Attr : access File_Attributes) return Long_Integer;
   --  Return the length (number of bytes) of the file

   procedure Find_File
     (N         : File_Name_Type;
      Found     : out File_Name_Type;
      Attr      : access File_Attributes);

   function Is_Regular_File
     (Name : C_File_Name;
      Attr : access File_Attributes) return Boolean;

   function OS_Time_To_GNAT_Time (T : OS_Time) return Time_Stamp_Type;
   --  Convert OS format time to GNAT format time stamp. If T is Invalid_Time,
   --  then returns Empty_Time_Stamp.
   --  Round to even seconds on Windows before conversion.
   --  Windows ALI files had timestamps rounded to even seconds historically.
   --  The rounding was originally done in GM_Split. Now that GM_Split no
   --  longer does it, we are rounding it here only for ALI files.

   ------------------------------
   -- Canonical_Case_File_Name --
   ------------------------------

   procedure Canonical_Case_File_Name (S : in out String) is
   begin
      if not File_Names_Case_Sensitive then
         To_Lower (S);
      end if;
   end Canonical_Case_File_Name;

   ---------------------------------
   -- Canonical_Case_Env_Var_Name --
   ---------------------------------

   procedure Canonical_Case_Env_Var_Name (S : in out String) is
   begin
      if not Env_Vars_Case_Sensitive then
         To_Lower (S);
      end if;
   end Canonical_Case_Env_Var_Name;

   ---------------------
   -- Executable_Name --
   ---------------------

   function Executable_Name
     (Name              : File_Name_Type;
      Only_If_No_Suffix : Boolean := False) return File_Name_Type
   is
      Exec_Suffix : String_Access;
      Add_Suffix  : Boolean;

   begin
      if Name = No_File then
         return No_File;
      end if;

      if Executable_Extension_On_Target = No_Name then
         Exec_Suffix := Get_Target_Executable_Suffix;
      else
         Get_Name_String (Executable_Extension_On_Target);
         Exec_Suffix := new String'(Name_Buffer (1 .. Name_Len));
      end if;

      if Exec_Suffix'Length /= 0 then
         Get_Name_String (Name);

         Add_Suffix := True;
         if Only_If_No_Suffix then
            for J in reverse 1 .. Name_Len loop
               if Name_Buffer (J) = '.' then
                  Add_Suffix := False;
                  exit;
               end if;

               exit when Is_Directory_Separator (Name_Buffer (J));
            end loop;
         end if;

         if Add_Suffix then
            declare
               Buffer : String := Name_Buffer (1 .. Name_Len);

            begin
               --  Get the file name in canonical case to accept as is. Names
               --  end with ".EXE" on Windows.

               Canonical_Case_File_Name (Buffer);

               --  If Executable doesn't end with the executable suffix, add it

               if Buffer'Length <= Exec_Suffix'Length
                 or else
                   Buffer (Buffer'Last - Exec_Suffix'Length + 1 .. Buffer'Last)
                     /= Exec_Suffix.all
               then
                  Name_Buffer
                    (Name_Len + 1 .. Name_Len + Exec_Suffix'Length) :=
                      Exec_Suffix.all;
                  Name_Len := Name_Len + Exec_Suffix'Length;
                  Free (Exec_Suffix);
                  return Name_Find;
               end if;
            end;
         end if;
      end if;

      Free (Exec_Suffix);
      return Name;
   end Executable_Name;

   ------------------
   -- Exit_Program --
   ------------------

   procedure Exit_Program (Exit_Code : Exit_Code_Type) is
   begin
      --  Some exit codes can't be used.
      --  Exit code 2 mean that progam terminated by SIGINT signal.
      --  3 mean that program terminated by abort on Windows or by SIGQUIT
      --  on Linux.
      --  6 mean that program terminated by SIGABRT signal

      OS_Exit
        (case Exit_Code is
            when E_Success => 0,
            when E_General => 1,
            when E_Subtool => 4,
            when E_Project => 5,
            when E_Fatal   => 7);
   end Exit_Program;

   ----------
   -- Fail --
   ----------

   procedure Fail (S : String) is
      Fatal_Exit : constant := 4;
   begin
      Set_Standard_Error;
      Write_Str (Simple_Name (Command_Name));
      Write_Str (": ");
      Write_Line (S);

      OS_Exit (Fatal_Exit);
   end Fail;

   -----------------
   -- File_Length --
   -----------------

   function File_Length
     (Name : C_File_Name;
      Attr : access File_Attributes) return Long_Integer
   is
      function Internal
        (F : Integer;
         N : C_File_Name;
         A : System.Address) return System.CRTL.int64;
      pragma Import (C, Internal, "__gnat_file_length_attr");

   begin
      --  The conversion from int64 to Long_Integer is ok here as this
      --  routine is only to be used by the compiler and we do not expect
      --  a unit to be larger than a 32bit integer.

      return Long_Integer (Internal (-1, Name, Attr.all'Address));
   end File_Length;

   ----------------
   -- File_Stamp --
   ----------------

   function File_Stamp (Name : String) return Time_Stamp_Type is
   begin
      --  File_Time_Stamp will always return Invalid_Time if the file does
      --  not exist, and OS_Time_To_GNAT_Time will convert this value to
      --  Empty_Time_Stamp. Therefore we do not need to first test whether
      --  the file actually exists, which saves a system call.

      return OS_Time_To_GNAT_Time (File_Time_Stamp (Name));
   end File_Stamp;

   function File_Stamp (Name : File_Name_Type) return Time_Stamp_Type is
   begin
      if Name = No_File then
         return Empty_Time_Stamp;
      end if;

      return File_Stamp (Get_Name_String (Name));
   end File_Stamp;

   function File_Stamp (Name : Path_Name_Type) return Time_Stamp_Type is
   begin
      return File_Stamp (File_Name_Type (Name));
   end File_Stamp;

   ---------------------
   -- File_Time_Stamp --
   ---------------------

   function File_Time_Stamp
     (Name : C_File_Name;
      Attr : access File_Attributes) return OS_Time
   is
      function Internal (N : C_File_Name; A : System.Address) return OS_Time;
      pragma Import (C, Internal, "__gnat_file_time_name_attr");
   begin
      return Internal (Name, Attr.all'Address);
   end File_Time_Stamp;

   function File_Time_Stamp
     (Name : Path_Name_Type;
      Attr : access File_Attributes) return Time_Stamp_Type
   is
   begin
      if Name = No_Path then
         return Empty_Time_Stamp;
      end if;

      Get_Name_String (Name);
      Name_Buffer (Name_Len + 1) := ASCII.NUL;
      return OS_Time_To_GNAT_Time
               (File_Time_Stamp (Name_Buffer'Address, Attr));
   end File_Time_Stamp;

   ---------------------
   -- File_Time_Stamp --
   ---------------------

   function File_Time_Stamp (Name : String) return Ada.Calendar.Time is
      FN : aliased constant String := Name & ASCII.NUL;
   begin
      --  Do not use Ada.Directories.Modification_Time directly because it
      --  raises exception on absent file.

      return File_Time_Stamp (FN'Address);
   end File_Time_Stamp;

   ---------------
   -- Find_File --
   ---------------

   procedure Find_File
     (N     : File_Name_Type;
      Found : out File_Name_Type;
      Attr  : access File_Attributes) is
   begin
      Attr.all := Unknown_Attributes;
      Get_Name_String (N);
      Name_Buffer (Name_Len + 1) := ASCII.NUL;

      if not Is_Regular_File (Name_Buffer (1)'Address, Attr) then
         Found := No_File;
         Attr.all := Unknown_Attributes;

      else
         Found := N;
      end if;
   end Find_File;

   -------------------
   -- Get_Directory --
   -------------------

   function Get_Directory (Name : File_Name_Type) return File_Name_Type is
   begin
      Get_Name_String (Name);

      for J in reverse 1 .. Name_Len loop
         if Is_Directory_Separator (Name_Buffer (J)) then
            Name_Len := J;
            return Name_Find;
         end if;
      end loop;

      Name_Len := 2;
      Name_Buffer (1) := '.';
      Name_Buffer (2) := Directory_Separator;
      return Name_Find;
   end Get_Directory;

   ----------------------------
   -- Is_Directory_Separator --
   ----------------------------

   function Is_Directory_Separator (C : Character) return Boolean is
   begin
      return C = Directory_Separator or else C = '/';
   end Is_Directory_Separator;

   ---------------------
   -- Is_Regular_File --
   ---------------------

   function Is_Regular_File
     (Name : C_File_Name; Attr : access File_Attributes) return Boolean
   is
      function Internal (N : C_File_Name; A : System.Address) return Integer;
      pragma Import (C, Internal, "__gnat_is_regular_file_attr");
   begin
      return Internal (Name, Attr.all'Address) /= 0;
   end Is_Regular_File;

   --------------------------
   -- OS_Time_To_GNAT_Time --
   --------------------------

   function OS_Time_To_GNAT_Time (T : OS_Time) return Time_Stamp_Type is
      use System.OS_Constants;

      type Int_Time is range -(2 ** (size_t'Size - Integer'(1)))
                          .. +(2 ** (size_t'Size - Integer'(1)) - 1);

      function To_C is new Ada.Unchecked_Conversion (OS_Time, Int_Time);
      function To_Ada is new Ada.Unchecked_Conversion (Int_Time, OS_Time);
      --  We need these routines to stay compatible with GNAT Community which
      --  doesn't yet have GNAT.OS_Lib.To_C/To_Ada routines.

      TS : Time_Stamp_Type;

      Y  : Year_Type;
      Mo : Month_Type;
      D  : Day_Type;
      H  : Hour_Type;
      Mn : Minute_Type;
      S  : Second_Type;

      Z : constant := Character'Pos ('0');

      function Even_T return OS_Time with Inline;
      --  If T is odd integer increase it by one and return.
      --  See OS_Time_To_GNAT_Time declaration comment for details.

      ------------
      -- Even_T --
      ------------

      function Even_T return OS_Time is
         TI : constant Int_Time := To_C (T);
      begin
         return To_Ada (if TI mod 2 > 0 then TI + 1 else TI);
      end Even_T;

   --  Start of processing for OS_Time_To_GNAT_Time

   begin
      if T = GNAT.OS_Lib.Invalid_Time then
         return Empty_Time_Stamp;
      end if;

      GM_Split
        ((if Target_OS = Windows then Even_T else T), Y, Mo, D, H, Mn, S);

      TS (01) := Character'Val (Z + Y / 1000);
      TS (02) := Character'Val (Z + (Y / 100) mod 10);
      TS (03) := Character'Val (Z + (Y / 10) mod 10);
      TS (04) := Character'Val (Z + Y mod 10);
      TS (05) := Character'Val (Z + Mo / 10);
      TS (06) := Character'Val (Z + Mo mod 10);
      TS (07) := Character'Val (Z + D / 10);
      TS (08) := Character'Val (Z + D mod 10);
      TS (09) := Character'Val (Z + H / 10);
      TS (10) := Character'Val (Z + H mod 10);
      TS (11) := Character'Val (Z + Mn / 10);
      TS (12) := Character'Val (Z + Mn mod 10);
      TS (13) := Character'Val (Z + S / 10);
      TS (14) := Character'Val (Z + S mod 10);

      return TS;
   end OS_Time_To_GNAT_Time;

   -----------------------
   -- Read_Library_Info --
   -----------------------

   function Read_Library_Info
     (Lib_File  : File_Name_Type;
      Fatal_Err : Boolean := False) return Text_Buffer_Ptr
   is
      File : File_Name_Type;
      Attr : aliased File_Attributes;
   begin
      Find_File (Lib_File, File, Attr'Access);
      return Read_Library_Info_From_Full
        (Full_Lib_File => File,
         Lib_File_Attr => Attr'Access,
         Fatal_Err     => Fatal_Err);
   end Read_Library_Info;

   ---------------------------------
   -- Read_Library_Info_From_Full --
   ---------------------------------

   function Read_Library_Info_From_Full
     (Full_Lib_File : File_Name_Type;
      Lib_File_Attr : access File_Attributes;
      Fatal_Err     : Boolean := False) return Text_Buffer_Ptr
   is
      Lib_FD : File_Descriptor;
      --  The file descriptor for the current library file. A negative value
      --  indicates failure to open the specified source file.

      Len : Integer;
      --  Length of source file text (ALI). If it doesn't fit in an integer
      --  we're probably stuck anyway (>2 gigs of source seems a lot, and
      --  there are other places in the compiler that make this assumption).

      Text : Text_Buffer_Ptr;
      --  Allocated text buffer

      Status : Boolean;
      pragma Warnings (Off, Status);
      --  For the calls to Close

   begin
      Current_Full_Lib_Name := Full_Lib_File;

      if Current_Full_Lib_Name = No_File then
         if Fatal_Err then
            Fail ("Cannot find: " & Name_Buffer (1 .. Name_Len));
         else
            return null;
         end if;
      end if;

      Get_Name_String (Current_Full_Lib_Name);
      Name_Buffer (Name_Len + 1) := ASCII.NUL;

      --  Open the library FD, note that we open in binary mode, because as
      --  documented in the spec, the caller is expected to handle either
      --  DOS or Unix mode files, and there is no point in wasting time on
      --  text translation when it is not required.

      Lib_FD := Open_Read (Name_Buffer'Address, Binary);

      if Lib_FD = Invalid_FD then
         if Fatal_Err then
            Fail ("Cannot open: " & Name_Buffer (1 .. Name_Len));
         else
            return null;
         end if;
      end if;

      --  Compute the length of the file (potentially also preparing other data
      --  like the timestamp and whether the file is read-only, for future use)

      Len := Integer (File_Length (Name_Buffer'Address, Lib_File_Attr));

      --  Read data from the file

      declare
         Actual_Len : Integer := 0;

         Lo : constant Text_Ptr := 0;
         --  Low bound for allocated text buffer

         Hi : Text_Ptr := Text_Ptr (Len);
         --  High bound for allocated text buffer. Note length is Len + 1
         --  which allows for extra EOF character at the end of the buffer.

      begin
         --  Allocate text buffer. Note extra character at end for EOF

         Text := new Text_Buffer (Lo .. Hi);

         --  Some systems have file types that require one read per line,
         --  so read until we get the Len bytes or until there are no more
         --  characters.

         Hi := Lo;
         loop
            Actual_Len := Read (Lib_FD, Text (Hi)'Address, Len);
            Hi := Hi + Text_Ptr (Actual_Len);
            exit when Actual_Len = Len or else Actual_Len <= 0;
         end loop;

         Text (Hi) := EOF;
      end;

      --  Read is complete, close file and we are done

      Close (Lib_FD, Status);
      --  The status should never be False. But, if it is, what can we do?
      --  So, we don't test it.

      return Text;

   end Read_Library_Info_From_Full;

   ------------------
   -- Strip_Suffix --
   ------------------

   function Strip_Suffix (Name : File_Name_Type) return File_Name_Type is
   begin
      Get_Name_String (Name);

      for J in reverse 2 .. Name_Len loop

         --  If we found the last '.', return part of Name that precedes it

         if Name_Buffer (J) = '.' then
            Name_Len := J - 1;
            return File_Name_Type (Name_Enter);
         end if;
      end loop;

      return Name;
   end Strip_Suffix;

----------------------------
-- Package Initialization --
----------------------------

   procedure Reset_File_Attributes (Attr : System.Address);
   pragma Import (C, Reset_File_Attributes, "__gnat_reset_attributes");

begin
   Reset_File_Attributes (Unknown_Attributes'Address);
end GPR.Osint;
