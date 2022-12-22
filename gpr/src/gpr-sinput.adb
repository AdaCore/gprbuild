------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 1992-2021, Free Software Foundation, Inc.         --
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

with Ada.Containers.Hashed_Maps;
with Ada.Unchecked_Deallocation;
with Ada.Unchecked_Conversion;

with GNAT.Byte_Order_Mark; use GNAT.Byte_Order_Mark;

with System; use System;

pragma Warnings (Off);
with System.WCh_Con; use System.WCh_Con;
with System.WCh_Cnv; use System.WCh_Cnv;
with System.Memory;
pragma Warnings (On);

with GPR.Err;
with GPR.Erroutc; use GPR.Erroutc;
with GPR.Names;   use GPR.Names;
with GPR.Opt;     use GPR.Opt;
with GPR.Output;  use GPR.Output;

package body GPR.Sinput is

   Lines_Initial : constant := 500;

   First : Boolean := True;
   --  Flag used when Load_File is called the first time, to set
   --  Main_Source_File.
   --  The flag is reset to False at the first call to Load_Project_File.
   --  Calling Reset_First sets it back to True.

   function Hash (Name : File_Name_Type) return Ada.Containers.Hash_Type is
     (Ada.Containers.Hash_Type (Name));

   package Source_Id_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => File_Name_Type,
      Element_Type    => Source_File_Index,
      Hash            => Hash,
      Equivalent_Keys => "=");

   Sources_Map : Source_Id_Maps.Map;

   procedure Free is new Ada.Unchecked_Deallocation
     (Lines_Table_Type, Lines_Table_Ptr);

   procedure Free (S : in out GPR.Sinput.Source_File_Record);
   --  Free allocated memory

   ---------------------------
   -- Add_Line_Tables_Entry --
   ---------------------------

   procedure Add_Line_Tables_Entry
     (S : in out Source_File_Record;
      P : Source_Ptr)
   is
      LL : Line_Number;

   begin
      --  Reallocate the lines tables if necessary

      if S.Last_Source_Line = S.Lines_Table'Last then
         declare
            New_Table : constant Lines_Table_Ptr :=
              new Lines_Table_Type (1 .. S.Last_Source_Line * 2);
         begin
            New_Table (1 .. S.Last_Source_Line) :=
              S.Lines_Table (1 .. S.Last_Source_Line);
            Free (S.Lines_Table);
            S.Lines_Table := New_Table;
         end;
      end if;

      S.Last_Source_Line := S.Last_Source_Line + 1;
      LL := S.Last_Source_Line;

      S.Lines_Table (LL) := P;

   end Add_Line_Tables_Entry;

   -------------------
   -- Check_For_BOM --
   -------------------

   procedure Check_For_BOM is
      BOM : BOM_Kind;
      Len : Natural;
      Tst : String (1 .. 5);
      C   : Character;

   begin
      for J in 1 .. 5 loop
         C := Source (Scan_Ptr + Source_Ptr (J) - 1);

         --  Definitely no BOM if EOF character marks either end of file, or
         --  an illegal non-BOM character if not at the end of file.

         if C = EOF then
            return;
         end if;

         Tst (J) := C;
      end loop;

      Read_BOM (Tst, Len, BOM, False);

      case BOM is
         when UTF8_All =>
            Scan_Ptr := Scan_Ptr + Source_Ptr (Len);
            Wide_Character_Encoding_Method := WCEM_UTF8;
            Upper_Half_Encoding := True;

         when UTF16_LE | UTF16_BE =>
            Set_Standard_Error;
            Write_Line ("UTF-16 encoding format not recognized");
            raise Unrecoverable_Error;

         when UTF32_LE | UTF32_BE =>
            Set_Standard_Error;
            Write_Line ("UTF-32 encoding format not recognized");
            raise Unrecoverable_Error;

         when Unknown =>
            null;

         when others =>
            raise Program_Error;
      end case;
   end Check_For_BOM;

   -----------------------------
   -- Clear_Source_File_Table --
   -----------------------------

   procedure Clear_Source_File_Table is
   begin
      for X in 1 .. Source_File.Last loop
         Free (Source_File.Table (X));
      end loop;

      Sources_Map.Clear;

      Source_File.Free;
      Sinput.Initialize;
   end Clear_Source_File_Table;

   ----------
   -- Free --
   ----------

   procedure Free (S : in out GPR.Sinput.Source_File_Record) is
      Lo : constant Source_Ptr := S.Source_First;
      Hi : constant Source_Ptr := S.Source_Last;
      subtype Actual_Source_Buffer is Source_Buffer (Lo .. Hi);
      --  Physical buffer allocated

      type Actual_Source_Ptr is access Actual_Source_Buffer;
      --  This is the pointer type for the physical buffer allocated

      procedure Free is new Ada.Unchecked_Deallocation
        (Actual_Source_Buffer, Actual_Source_Ptr);

      pragma Suppress (All_Checks);

      pragma Warnings (Off);
      --  The following unchecked conversion is aliased safe, since it
      --  is not used to create improperly aliased pointer values.

      function To_Actual_Source_Ptr is new
        Ada.Unchecked_Conversion (Address, Actual_Source_Ptr);

      pragma Warnings (On);

      Actual_Ptr : Actual_Source_Ptr :=
                     To_Actual_Source_Ptr (S.Source_Text (Lo)'Address);

   begin
      Free (Actual_Ptr);
      Free (S.Lines_Table);
   end Free;

   --------------------
   -- Full_File_Name --
   --------------------

   function Full_File_Name (S : Source_File_Index) return File_Name_Type is
   begin
      return Source_File.Table (S).Full_File_Name;
   end Full_File_Name;

   -------------------
   -- Full_Ref_Name --
   -------------------

   function Full_Ref_Name (S : Source_File_Index) return File_Name_Type is
   begin
      return Source_File.Table (S).Full_Ref_Name;
   end Full_Ref_Name;

   -----------------------
   -- Get_Column_Number --
   -----------------------

   function Get_Column_Number (P : Source_Ptr) return Column_Number is
      S      : Source_Ptr;
      C      : Column_Number;
      Sindex : Source_File_Index;
      Src    : Source_Buffer_Ptr;

   begin
      --  If the input source pointer is not a meaningful value then return
      --  at once with column number 1. This can happen for a file not found
      --  condition for a file loaded indirectly by RTE, and also perhaps on
      --  some unknown internal error conditions. In either case we certainly
      --  don't want to blow up.

      if P < 1 then
         return 1;

      else
         Sindex := Get_Source_File_Index (P);
         Src := Source_File.Table (Sindex).Source_Text;
         S := Line_Start (P);
         C := 1;

         while S < P loop
            if Src (S) = ASCII.HT then
               C := (C - 1) / 8 * 8 + (8 + 1);
               S := S + 1;

            --  Deal with wide character case, but don't include brackets
            --  notation in this circuit, since we know that this will
            --  display unencoded (no one encodes brackets notation).

            elsif Src (S) /= '[' and then Is_Start_Of_Wide_Char (Src, S) then
               C := C + 1;
               Skip_Wide (Src, S);

            --  Normal (non-wide) character case or brackets sequence

            else
               C := C + 1;
               S := S + 1;
            end if;
         end loop;

         return C;
      end if;
   end Get_Column_Number;

   ---------------------
   -- Get_Line_Number --
   ---------------------

   function Get_Line_Number
     (P : Source_Ptr) return Line_Number
   is
      Sfile : Source_File_Index;
      Table : Lines_Table_Ptr;
      Lo    : Line_Number;
      Hi    : Line_Number;
      Mid   : Line_Number;
      Loc   : Source_Ptr;

   begin
      --  If the input source pointer is not a meaningful value then return
      --  at once with line number 1. This can happen for a file not found
      --  condition for a file loaded indirectly by RTE, and also perhaps on
      --  some unknown internal error conditions. In either case we certainly
      --  don't want to blow up.

      if P < 1 then
         return 1;

      --  Otherwise we can do the binary search

      else
         Sfile := Get_Source_File_Index (P);
         Loc   := P;
         Table := Source_File.Table (Sfile).Lines_Table;
         Lo    := 1;
         Hi    := Source_File.Table (Sfile).Last_Source_Line;

         loop
            Mid := (Lo + Hi) / 2;

            if Loc < Table (Mid) then
               Hi := Mid - 1;

            else -- Loc >= Table (Mid)

               if Mid = Hi or else
                  Loc < Table (Mid + 1)
               then
                  return Mid;
               else
                  Lo := Mid + 1;
               end if;

            end if;

         end loop;
      end if;
   end Get_Line_Number;

   ---------------------------
   -- Get_Source_File_Index --
   ---------------------------

   function Get_Source_File_Index (S : Source_Ptr) return Source_File_Index is
   begin
      return Source_File_Index_Table (Int (S) / Source_Align);
   end Get_Source_File_Index;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Source_File.Init;
   end Initialize;

   ----------------------
   -- Last_Source_File --
   ----------------------

   function Last_Source_File return Source_File_Index is
   begin
      return Source_File.Last;
   end Last_Source_File;

   ----------------
   -- Line_Start --
   ----------------

   function Line_Start (P : Source_Ptr) return Source_Ptr is
      Sindex : constant Source_File_Index := Get_Source_File_Index (P);
      Src    : constant Source_Buffer_Ptr :=
                 Source_File.Table (Sindex).Source_Text;
      Sfirst : constant Source_Ptr :=
                 Source_File.Table (Sindex).Source_First;
      S      : Source_Ptr;

   begin
      if Src = null then
         return No_Location;
      end if;

      S := P;
      while S > Sfirst
        and then Src (S - 1) /= ASCII.CR
        and then Src (S - 1) /= ASCII.LF
      loop
         S := S - 1;
      end loop;

      return S;
   end Line_Start;

   function Line_Start
     (L : Line_Number;
      S : Source_File_Index) return Source_Ptr
   is
   begin
      return Source_File.Table (S).Lines_Table (L);
   end Line_Start;

   ---------------
   -- Load_File --
   ---------------

   function Load_File (Path : String) return Source_File_Index is
      Src  : Source_Buffer_Ptr;
      X    : Source_File_Index;
      Lo   : Source_Ptr;
      Hi   : Source_Ptr;

      Source_File_FD : File_Descriptor;
      --  The file descriptor for the current source file. A negative value
      --  indicates failure to open the specified source file.

      Len : Integer;
      --  Length of file (assume no more than 2 gigabytes of source)

      Actual_Len : Integer;

      Position : Source_Id_Maps.Cursor;
      Inserted : Boolean;
      Path_Id  : File_Name_Type;
      File_Id  : File_Name_Type;

   begin
      if Path = "" then
         return No_Source_File;
      end if;

      Path_Id := Get_File_Name_Id (Path);

      Sources_Map.Insert
        (Path_Id, Source_File.Last + 1, Position, Inserted);

      if not Inserted then
         return Result : constant Source_File_Index :=
           Source_Id_Maps.Element (Position)
         do
            pragma Assert
              (Source_File.Table (Result).Full_Debug_Name = Path_Id,
               "insertion failed for "
               & Get_Name_String (Source_File.Table (Result).Full_Debug_Name)
               & ' ' & Get_Name_String (Path_Id));
            pragma Assert
              (Source_File.Table (Result).Full_File_Name = Path_Id,
               "insertion failed for "
               & Source_File.Table (Result).Full_File_Name'Img & Path_Id'Img);
            pragma Assert
              (Source_File.Table (Result).Full_Ref_Name = Path_Id,
               "insertion failed for "
               & Source_File.Table (Result).Full_Ref_Name'Img & Path_Id'Img);
         end return;
      end if;

      Source_File.Increment_Last;
      X := Source_File.Last;

      Lo :=
        (if X = Source_File.First then First_Source_Ptr
         else
           ((Source_File.Table (X - 1).Source_Last + Source_Align) /
            Source_Align) *
           Source_Align);

      Name_Buffer (Name_Len + 1) := ASCII.NUL;

      --  Open the source FD, note that we open in binary mode, because as
      --  documented in the spec, the caller is expected to handle either
      --  DOS or Unix mode files, and there is no point in wasting time on
      --  text translation when it is not required.

      Source_File_FD := Open_Read (Name_Buffer'Address, Binary);

      if Source_File_FD = Invalid_FD then
         Source_File.Decrement_Last;
         Sources_Map.Delete (Position);
         return No_Source_File;

      end if;

      Len := Integer (File_Length (Source_File_FD));

      --  Set Hi so that length is one more than the physical length, allowing
      --  for the extra EOF character at the end of the buffer

      Hi := Lo + Source_Ptr (Len);

      --  Do the actual read operation

      declare
         subtype Actual_Source_Buffer is Source_Buffer (Lo .. Hi);
         --  Physical buffer allocated

         type Actual_Source_Ptr is access Actual_Source_Buffer;
         --  This is the pointer type for the physical buffer allocated

         Actual_Ptr : constant Actual_Source_Ptr := new Actual_Source_Buffer;
         --  And this is the actual physical buffer

      begin
         --  Allocate source buffer, allowing extra character at end for EOF

         --  Some systems have file types that require one read per line,
         --  so read until we get the Len bytes or until there are no more
         --  characters.

         Hi := Lo;
         loop
            Actual_Len := Read (Source_File_FD, Actual_Ptr (Hi)'Address, Len);
            Hi := Hi + Source_Ptr (Actual_Len);
            exit when Actual_Len = Len or else Actual_Len <= 0;
         end loop;

         Actual_Ptr (Hi) := EOF;

         --  Now we need to work out the proper virtual origin pointer to
         --  return. This is exactly Actual_Ptr (0)'Address, but we have to
         --  be careful to suppress checks to compute this address.

         declare
            pragma Suppress (All_Checks);

            pragma Warnings (Off);
            --  The following unchecked conversion is aliased safe, since it
            --  is not used to create improperly aliased pointer values.

            function To_Source_Buffer_Ptr is new
              Ada.Unchecked_Conversion (Address, Source_Buffer_Ptr);

            pragma Warnings (On);

         begin
            Src := To_Source_Buffer_Ptr (Actual_Ptr (0)'Address);
         end;
      end;

      --  Read is complete, close the file and we are done (no need to test
      --  status from close, since we have successfully read the file).

      Close (Source_File_FD);

      --  Get the file name, without path information

      declare
         Index : Positive := Path'Last;

      begin
         while Index > Path'First loop
            exit when Is_Directory_Separator (Path (Index - 1));
            Index := Index - 1;
         end loop;

         Name_Len := Path'Last - Index + 1;
         Name_Buffer (1 .. Name_Len) := Path (Index .. Path'Last);
         File_Id := Name_Find;
      end;

      declare
         S : Source_File_Record renames Source_File.Table (X);

      begin
         S := (File_Name         => File_Id,
               Reference_Name    => File_Id,
               Debug_Source_Name => File_Id,
               Full_Debug_Name   => Path_Id,
               Full_File_Name    => Path_Id,
               Full_Ref_Name     => Path_Id,
               Source_Text       => Src,
               Source_First      => Lo,
               Source_Last       => Hi,
               Last_Source_Line  => 1,
               Lines_Table       => new Lines_Table_Type (1 .. Lines_Initial));

         S.Lines_Table (1) := Lo;
      end;

      Set_Source_File_Index_Table (X);

      if First then
         Main_Source_File := X;
         First := False;
      end if;

      return X;
   end Load_File;

   ----------------------
   -- Num_Source_Files --
   ----------------------

   function Num_Source_Files return Nat is
   begin
      return Int (Source_File.Last) - Int (Source_File.First) + 1;
   end Num_Source_Files;

   ----------------------
   -- Num_Source_Lines --
   ----------------------

   function Num_Source_Lines (S : Source_File_Index) return Nat is
   begin
      return Nat (Source_File.Table (S).Last_Source_Line);
   end Num_Source_Lines;

   --------------------
   -- Reference_Name --
   --------------------

   function Reference_Name (S : Source_File_Index) return File_Name_Type is
   begin
      return Source_File.Table (S).Reference_Name;
   end Reference_Name;

   -----------------
   -- Reset_First --
   -----------------

   procedure Reset_First is
   begin
      First := True;
   end Reset_First;

   --------------------------------
   -- Restore_Project_Scan_State --
   --------------------------------

   procedure Restore_Project_Scan_State
     (Saved_State : Saved_Project_Scan_State)
   is
   begin
      Restore_Scan_State (Saved_State.Scan_State);
      Source              := Saved_State.Source;
      Current_Source_File := Saved_State.Current_Source_File;
   end Restore_Project_Scan_State;

   -----------------------------
   -- Save_Project_Scan_State --
   -----------------------------

   procedure Save_Project_Scan_State
     (Saved_State : out Saved_Project_Scan_State)
   is
   begin
      Save_Scan_State (Saved_State.Scan_State);
      Saved_State.Source              := Source;
      Saved_State.Current_Source_File := Current_Source_File;
   end Save_Project_Scan_State;

   ---------------------------------
   -- Set_Source_File_Index_Table --
   ---------------------------------

   procedure Set_Source_File_Index_Table (Xnew : Source_File_Index) is
      Ind : Int;
      SP  : Source_Ptr;
      SL  : constant Source_Ptr := Source_File.Table (Xnew).Source_Last;
   begin
      SP  := Source_File.Table (Xnew).Source_First;
      pragma Assert (SP mod Source_Align = 0);
      Ind := Int (SP) / Source_Align;
      while SP <= SL loop
         Source_File_Index_Table (Ind) := Xnew;
         SP := SP + Source_Align;
         Ind := Ind + 1;
      end loop;
   end Set_Source_File_Index_Table;

   ---------------
   -- Skip_Wide --
   ---------------

   procedure Skip_Wide (S : Source_Buffer_Ptr; P : in out Source_Ptr) is

      function Skip_Char return Character;
      --  Function to skip one character of wide character escape sequence

      ---------------
      -- Skip_Char --
      ---------------

      function Skip_Char return Character is
      begin
         P := P + 1;
         return S (P - 1);
      end Skip_Char;

      function WC_Skip is new Char_Sequence_To_UTF_32 (Skip_Char);

      Discard : UTF_32_Code;
      pragma Warnings (Off, Discard);

   --  Start of processing for Skip_Wide

   begin
      Discard := WC_Skip (Skip_Char, Wide_Character_Encoding_Method);
   end Skip_Wide;

   ----------------------------
   -- Source_File_Is_Subunit --
   ----------------------------

   function Source_File_Is_Subunit (X : Source_File_Index) return Boolean is
   begin
      --  Nothing to do if X is no source file, so simply return False

      if X = No_Source_File then
         return False;
      end if;

      Err.Scanner.Initialize_Scanner (X, Err.Scanner.Ada);

      --  No error for special characters that are used for preprocessing

      Err.Scanner.Set_Special_Character ('#');
      Err.Scanner.Set_Special_Character ('$');

      --  We scan past junk to the first interesting compilation unit token, to
      --  see if it is SEPARATE. We ignore WITH keywords during this and also
      --  PRIVATE. The reason for ignoring PRIVATE is that it handles some
      --  error situations, and also to handle PRIVATE WITH in Ada 2005 mode.

      while Token = Tok_With
        or else Token = Tok_Private
        or else (Token not in Token_Class_Cunit and then Token /= Tok_EOF)
      loop
         Err.Scanner.Scan;
      end loop;

      Err.Scanner.Reset_Special_Characters;

      return Token = Tok_Separate;
   end Source_File_Is_Subunit;

   ----------------------
   -- Source_File_Trim --
   ----------------------

   procedure Source_File_Trim (Last : Source_File_Index) is
   begin
      for Index in Last + 1 .. GPR.Sinput.Source_File.Last loop
         Sources_Map.Delete
           (GPR.Sinput.Source_File.Table (Index).Full_File_Name);
         Free (GPR.Sinput.Source_File.Table (Index));
      end loop;
      GPR.Sinput.Source_File.Set_Last (Last);
   end Source_File_Trim;

   ------------------
   -- Source_First --
   ------------------

   function Source_First (S : Source_File_Index) return Source_Ptr is
   begin
      return Source_File.Table (S).Source_First;
   end Source_First;

   -----------------
   -- Source_Last --
   -----------------

   function Source_Last (S : Source_File_Index) return Source_Ptr is
   begin
      return Source_File.Table (S).Source_Last;
   end Source_Last;

   -----------------
   -- Source_Text --
   -----------------

   function Source_Text (S : Source_File_Index) return Source_Buffer_Ptr is
   begin
      return Source_File.Table (S).Source_Text;
   end Source_Text;

end GPR.Sinput;
