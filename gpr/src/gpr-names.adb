------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2021, Free Software Foundation, Inc.         --
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

with Ada.Containers.Indefinite_Vectors;
with Ada.Text_IO; use Ada.Text_IO;

with Interfaces; use Interfaces;

with GPR.Cset;   use GPR.Cset;
with GPR.Output; use GPR.Output;
with GPR.Debug;

with GNAT.Case_Util;

package body GPR.Names is

   --  This table stores the actual string names. Although logically there is
   --  no need for a terminating character (since the length is stored in the
   --  name entry table), we still store a NUL character at the end of every
   --  name (for convenience in interfacing to the C world).

   Hash_Num : constant Int := 2**16;
   --  Number of headers in the hash table. Current hash algorithm is closely
   --  tailored to this choice, so it can only be changed if a corresponding
   --  change is made to the hash algorithm.

   Hash_Max : constant Int := Hash_Num - 1;
   --  Indexes in the hash header table run from 0 to Hash_Num - 1

   subtype Hash_Index_Type is Int range 0 .. Hash_Max;
   --  Range of hash index values

   Hash_Table : array (Hash_Index_Type) of Name_Id := (others => No_Name);
   --  The hash table is used to locate existing entries in the names table.
   --  The entries point to the first names table entry whose hash value
   --  matches the hash code. Then subsequent names table entries with the
   --  same hash code value are linked through the Hash_Link fields.

   type Name_Entry (Name_Len : Natural) is record
      Value : String (1 .. Name_Len);

      Hash_Link : Name_Id;
      --  Link to next entry in names table for same hash code

      Int_Info : Int;
      --  Int Value associated with this name

   end record;

   --  This is the table that is referenced by Name_Id entries.
   --  It contains one entry for each unique name in the table.

   subtype Valid_Name_Id is Name_Id range First_Name_Id .. Name_Id'Last;

   pragma Suppress (Container_Checks);
   package Name_Vectors is new Ada.Containers.Indefinite_Vectors
     (Valid_Name_Id, Name_Entry);

   Name_Entries : Name_Vectors.Vector;

   -----------------------
   -- Local Subprograms --
   -----------------------

   function Hash return Hash_Index_Type;
   pragma Inline (Hash);
   --  Compute hash code for name stored in Name_Buffer (length in Name_Len)

   function In_Wide_Character_Range (C : Char_Code) return Boolean;
   pragma Inline (In_Wide_Character_Range);
   --  Determines if the given character code is in range of the type
   --  Wide_Character, and if so, returns True. If not, returns False.

   -----------------------------
   -- Add_Char_To_Name_Buffer --
   -----------------------------

   procedure Add_Char_To_Name_Buffer (C : Character) is
   begin
      if Name_Len < Name_Buffer'Last then
         Name_Len := Name_Len + 1;
         Name_Buffer (Name_Len) := C;
      end if;
   end Add_Char_To_Name_Buffer;

   ----------------------------
   -- Add_Nat_To_Name_Buffer --
   ----------------------------

   procedure Add_Nat_To_Name_Buffer (V : Nat) is
   begin
      if V >= 10 then
         Add_Nat_To_Name_Buffer (V / 10);
      end if;

      Add_Char_To_Name_Buffer (Character'Val (Character'Pos ('0') + V rem 10));
   end Add_Nat_To_Name_Buffer;

   ----------------------------
   -- Add_Str_To_Name_Buffer --
   ----------------------------

   procedure Add_Str_To_Name_Buffer (S : String) is
      Start : constant Positive := Name_Len + 1;
   begin
      Name_Len := Name_Len + S'Length;

      if Name_Len <= Name_Buffer'Last then
         Name_Buffer (Start .. Name_Len) := S;

      elsif Start <= Name_Buffer'Last then
         Name_Buffer (Start .. Name_Buffer'Last) :=
           S (S'First .. S'First + Name_Buffer'Last - Start);
      end if;

   end Add_Str_To_Name_Buffer;

   -------------------
   -- Get_Character --
   -------------------

   function Get_Character (C : Char_Code) return Character is
   begin
      pragma Assert (C <= 255);
      return Character'Val (C);
   end Get_Character;

   -----------------------
   -- Get_Lower_Name_Id --
   -----------------------

   function Get_Lower_Name_Id (Name : String) return Name_Id is
   begin
      Set_Name_Buffer (Name);
      GNAT.Case_Util.To_Lower (Name_Buffer (1 .. Name_Len));
      return Name_Find;
   end Get_Lower_Name_Id;

   -----------------
   -- Get_Name_Id --
   -----------------

   function Get_Name_Id (Name : String) return Name_Id is
   begin
      Set_Name_Buffer (Name);
      return Name_Find;
   end Get_Name_Id;

   -------------------
   -- Get_Char_Code --
   -------------------

   function Get_Char_Code (C : Character) return Char_Code is
   begin
      return Char_Code'Val (Character'Pos (C));
   end Get_Char_Code;

   ---------------------
   -- Get_Name_String --
   ---------------------

   --  Procedure version leaving result in Name_Buffer, length in Name_Len

   procedure Get_Name_String (Id : Name_Id) is
   begin
      if Debug.Debug_Flag_A then
         Put ("<<<< Accessing index" & Id'Img &
                " (procedure Get_Name_String)");
      end if;

      pragma Assert (Is_Valid_Name (Id));

      Set_Name_Buffer (Name_Entries (Id).Value);

      if Debug.Debug_Flag_A then
         Put_Line (" Found: '" & Name_Buffer (1 .. Name_Len) & "' >>>>");
      end if;
   end Get_Name_String;

   procedure Get_Name_String (Id : Unit_Name_Type) is
   begin
      Get_Name_String (Name_Id (Id));
   end Get_Name_String;

   procedure Get_Name_String (Id : File_Name_Type) is
   begin
      Get_Name_String (Name_Id (Id));
   end Get_Name_String;

   procedure Get_Name_String (Id : Path_Name_Type) is
   begin
      Get_Name_String (Name_Id (Id));
   end Get_Name_String;

   ---------------------
   -- Get_Name_String --
   ---------------------

   --  Function version returning a string

   function Get_Name_String (Id : Name_Id) return String is
   begin
      if Debug.Debug_Flag_A then
         Put ("<<<< Accessing index" & Id'Img &
                " (function Get_Name_String)");
      end if;

      pragma Assert (Is_Valid_Name (Id), "Invalid Id" & Id'Img);

      return R : constant String := Name_Entries (Id).Value do
         if Debug.Debug_Flag_A then
            Put_Line (" Found: '" & R & "' >>>>");
         end if;
      end return;
   end Get_Name_String;

   function Get_Name_String (Id : Unit_Name_Type) return String is
   begin
      return Get_Name_String (Name_Id (Id));
   end Get_Name_String;

   function Get_Name_String (Id : File_Name_Type) return String is
   begin
      return Get_Name_String (Name_Id (Id));
   end Get_Name_String;

   function Get_Name_String (Id : Path_Name_Type) return String is
   begin
      return Get_Name_String (Name_Id (Id));
   end Get_Name_String;

   --------------------------------
   -- Get_Name_String_And_Append --
   --------------------------------

   procedure Get_Name_String_And_Append (Id : Name_Id) is
   begin
      if Debug.Debug_Flag_A then
         Put ("<<<< Accessing index" & Id'Img &
                " (Get_Name_String_And_Append)");
      end if;

      pragma Assert (Is_Valid_Name (Id));

      Add_Str_To_Name_Buffer (Name_Entries (Id).Value);

      if Debug.Debug_Flag_A then
         Put_Line (" Found: '" & Name_Entries (Id).Value & "' >>>>");
      end if;
   end Get_Name_String_And_Append;

   procedure Get_Name_String_And_Append (Id : File_Name_Type) is
   begin
      Get_Name_String_And_Append (Name_Id (Id));
   end Get_Name_String_And_Append;

   procedure Get_Name_String_And_Append (Id : Path_Name_Type) is
   begin
      Get_Name_String_And_Append (Name_Id (Id));
   end Get_Name_String_And_Append;

   -------------------------
   -- Get_Name_Table_Int --
   -------------------------

   function Get_Name_Table_Int (Id : Name_Id) return Int is
   begin
      pragma Assert (Is_Valid_Name (Id));
      return Name_Entries (Id).Int_Info;
   end Get_Name_Table_Int;

   function Get_Name_Table_Int (Id : Unit_Name_Type) return Int is
   begin
      return Get_Name_Table_Int (Name_Id (Id));
   end Get_Name_Table_Int;

   function Get_Name_Table_Int (Id : File_Name_Type) return Int is
   begin
      return Get_Name_Table_Int (Name_Id (Id));
   end Get_Name_Table_Int;

   ----------
   -- Hash --
   ----------

   function Hash return Hash_Index_Type is

      --  This hash function looks at every character, in order to make it
      --  likely that similar strings get different hash values. The rotate by
      --  7 bits has been determined empirically to be good, and it doesn't
      --  lose bits like a shift would. The final conversion can't overflow,
      --  because the table is 2**16 in size. This function probably needs to
      --  be changed if the hash table size is changed.

      --  Note that we could get some speed improvement by aligning the string
      --  to 32 or 64 bits, and doing word-wise xor's. We could also implement
      --  a growable table. It doesn't seem worth the trouble to do those
      --  things, for now.

      Result : Unsigned_16 := 0;

   begin
      for J in 1 .. Name_Len loop
         Result := Rotate_Left (Result, 7) xor Character'Pos (Name_Buffer (J));
      end loop;

      return Hash_Index_Type (Result);
   end Hash;

   ------------------------
   -- In_Character_Range --
   ------------------------

   function In_Character_Range (C : Char_Code) return Boolean is
   begin
      return (C <= 255);
   end In_Character_Range;

   -----------------------------
   -- In_Wide_Character_Range --
   -----------------------------

   function In_Wide_Character_Range (C : Char_Code) return Boolean is
   begin
      return (C <= 65535);
   end In_Wide_Character_Range;

   -------------------
   -- Is_Valid_Name --
   -------------------

   function Is_Valid_Name (Id : Name_Id) return Boolean is
   begin
      return Id in Name_Entries.First_Index .. Name_Entries.Last_Index;
   end Is_Valid_Name;

   --------------------
   -- Length_Of_Name --
   --------------------

   function Length_Of_Name (Id : Name_Id) return Nat is
   begin
      return Int (Name_Entries (Id).Name_Len);
   end Length_Of_Name;

   function Length_Of_Name (Id : File_Name_Type) return Nat is
   begin
      return Int (Name_Entries (Name_Id (Id)).Name_Len);
   end Length_Of_Name;

   ----------------
   -- Name_Enter --
   ----------------

   function Name_Enter return Name_Id is
   begin
      Name_Entries.Append
        ((Name_Len  => Name_Len,
          Value     => Name_Buffer (1 .. Name_Len),
          Int_Info  => 0,
          Hash_Link => No_Name), 1);

      if Debug.Debug_Flag_A then
         Put_Line ("<<<< Appending: '" & Name_Buffer (1 .. Name_Len) &
                     "' with index" & Name_Entries.Last_Index'Img &
                     " (Name_Enter) >>>>");
      end if;

      return Name_Entries.Last_Index;
   end Name_Enter;

   ---------------
   -- Name_Find --
   ---------------

   function Name_Find return Name_Id is
      New_Id : Name_Id;
      --  Id of entry in hash search, and value to be returned

      Hash_Index : Hash_Index_Type;
      --  Computed hash index

   begin

      Hash_Index := Hash;
      New_Id := Hash_Table (Hash_Index);

      if New_Id = No_Name then
         Hash_Table (Hash_Index) := Name_Entries.Last_Index + 1;

      else
         Search : loop
            if Name_Entries (New_Id).Value /= Name_Buffer (1 .. Name_Len) then
               goto No_Match;
            end if;

            if Debug.Debug_Flag_A then
               Put_Line ("<<<< Found index" & New_Id'Img & " for: '"
                         & Name_Buffer (1 .. Name_Len) & "' (Name_Find) >>>>");
            end if;

            return New_Id;

            --  Current entry in hash chain does not match

            <<No_Match>>
            if Name_Entries (New_Id).Hash_Link /= No_Name then
               New_Id := Name_Entries (New_Id).Hash_Link;
            else
               Name_Entries (New_Id).Hash_Link := Name_Entries.Last_Index + 1;
               exit Search;
            end if;
         end loop Search;
      end if;

      --  We fall through here only if a matching entry was not found in the
      --  hash table. We now create a new entry in the names table. The hash
      --  link pointing to the new entry (Name_Entries.Last+1) has been set.

      Name_Entries.Append
        ((Name_Len  => Name_Len,
          Value     => Name_Buffer (1 .. Name_Len),
          Hash_Link => No_Name,
          Int_Info  => 0), 1);

      if Debug.Debug_Flag_A then
         Put_Line ("<<<< Appending: '" & Name_Buffer (1 .. Name_Len) &
                     "' with index" & Name_Entries.Last_Index'Img &
                     " (Name_Find) >>>>");
      end if;

      return Name_Entries.Last_Index;
   end Name_Find;

   function Name_Find return Unit_Name_Type is
      Id : Name_Id;
   begin
      Id := Name_Find;
      return Unit_Name_Type (Id);
   end Name_Find;

   function Name_Find return File_Name_Type is
      Id : Name_Id;
   begin
      Id := Name_Find;
      return File_Name_Type (Id);
   end Name_Find;

   function Name_Find return Path_Name_Type is
      Id : Name_Id;
   begin
      Id := Name_Find;
      return Path_Name_Type (Id);
   end Name_Find;

   ----------------
   -- Set_Casing --
   ----------------

   procedure Set_Casing (C : Casing_Type) is
      Ptr : Natural;

      After_Und : Boolean := True;
      --  True at start of string, and after an underline character or after
      --  any other special character that is not a normal identifier char).

   begin
      Ptr := 1;

      while Ptr <= Name_Len loop

         --  Underscore, or non-identifer character (error case)

         if Name_Buffer (Ptr) = '_'
            or else not Identifier_Char (Name_Buffer (Ptr))
         then
            After_Und := True;
            Ptr := Ptr + 1;

         --  Lower case letter

         elsif Is_Lower_Case_Letter (Name_Buffer (Ptr)) then
            if C = All_Upper_Case
              or else (After_Und and then C = Mixed_Case)
            then
               Name_Buffer (Ptr) := Fold_Upper (Name_Buffer (Ptr));
            end if;

            After_Und := False;
            Ptr := Ptr + 1;

         --  Upper case letter

         elsif Is_Upper_Case_Letter (Name_Buffer (Ptr)) then
            if C = All_Lower_Case
              or else (not After_Und and then C = Mixed_Case)
            then
               Name_Buffer (Ptr) := Fold_Lower (Name_Buffer (Ptr));
            end if;

            After_Und := False;
            Ptr := Ptr + 1;

         --  Other identifier character (must be digit)

         else
            After_Und := False;
            Ptr := Ptr + 1;
         end if;
      end loop;
   end Set_Casing;

   -------------------------
   -- Set_Name_Table_Int --
   -------------------------

   procedure Set_Name_Table_Int (Id : Name_Id; Val : Int) is
   begin
      pragma Assert (Is_Valid_Name (Id));
      Name_Entries (Id).Int_Info := Val;
   end Set_Name_Table_Int;

   procedure Set_Name_Table_Int (Id : Unit_Name_Type; Val : Int) is
   begin
      Set_Name_Table_Int (Name_Id (Id), Val);
   end Set_Name_Table_Int;

   procedure Set_Name_Table_Int (Id : File_Name_Type; Val : Int) is
   begin
      Set_Name_Table_Int (Name_Id (Id), Val);
   end Set_Name_Table_Int;

   ----------------------------
   -- Set_Name_Buffer --
   ----------------------------

   procedure Set_Name_Buffer (S : String) is
   begin
      Name_Len := S'Length;
      Name_Buffer (1 .. Name_Len) := S;
   end Set_Name_Buffer;

   -----------------------------
   -- Store_Encoded_Character --
   -----------------------------

   procedure Store_Encoded_Character (C : Char_Code) is
   begin
      Name_Len := Name_Len + 1;

      if In_Character_Range (C) then
         declare
            CC : constant Character := Get_Character (C);
         begin
            if CC in 'a' .. 'z' | '0' .. '9' then
               Name_Buffer (Name_Len) := CC;
            else
               Name_Buffer (Name_Len) := 'U';
               Name_Len               := Name_Len + 2;
               Hex_Image (Word (C), Name_Buffer (Name_Len - 1 .. Name_Len));
            end if;
         end;

      elsif In_Wide_Character_Range (C) then
         Name_Buffer (Name_Len) := 'W';
         Name_Len := Name_Len + 4;
         Hex_Image (Word (C), Name_Buffer (Name_Len - 3 .. Name_Len));
      else
         Name_Buffer (Name_Len) := 'W';
         Name_Len := Name_Len + 1;
         Name_Buffer (Name_Len) := 'W';
         Name_Len := Name_Len + 8;
         Hex_Image (Word (C), Name_Buffer (Name_Len - 7 .. Name_Len));
      end if;
   end Store_Encoded_Character;

   --------
   -- wn --
   --------

   procedure wn2 (Id : Name_Id) is
   begin
      if not Id'Valid then
         Write_Line ("<invalid name_id>");

      elsif Id = No_Name then
         Write_Line ("<No_Name>");

      elsif Id = Error_Name then
         Write_Line ("<Error_Name>");

      else
         Write_Line (Name_Entries (Id).Value);
      end if;
   end wn2;

   ----------------
   -- Write_Name --
   ----------------

   procedure Write_Name (Id : Name_Id) is
   begin
      pragma Assert
        (Is_Valid_Name (Id),
         "invalid id" & Id'Img
         & Name_Entries.First_Index'Img & Name_Entries.Last_Index'Img);

      Get_Name_String (Id);
      Write_Str (Name_Buffer (1 .. Name_Len));
   end Write_Name;

   procedure Write_Name (Id : Path_Name_Type) is
   begin
      Write_Name (Name_Id (Id));
   end Write_Name;

   procedure Write_Name (Id : File_Name_Type) is
   begin
      Write_Name (Name_Id (Id));
   end Write_Name;

   ---------------------
   -- Write_Unit_Name --
   ---------------------

   procedure Write_Unit_Name (U : Unit_Name_Type)
   is
   begin
      Get_Name_String (U);
      Write_Str (Name_Buffer (1 .. Name_Len - 2));

      if Name_Buffer (Name_Len) = 's' then
         Write_Str (" (spec)");
      else
         Write_Str (" (body)");
      end if;
   end Write_Unit_Name;

end GPR.Names;
