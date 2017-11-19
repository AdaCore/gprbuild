------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2015, Free Software Foundation, Inc.         --
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

with GNAT.Table;
with Interfaces; use Interfaces;

with GPR.Cset;   use GPR.Cset;
with GPR.Output; use GPR.Output;

package body GPR.Names is

   Name_Chars_Initial   : constant := 50_000;
   Name_Chars_Increment : constant := 100;

   Names_Initial   : constant := 6_000;
   Names_Increment : constant := 100;

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

   Hash_Table : array (Hash_Index_Type) of Name_Id;
   --  The hash table is used to locate existing entries in the names table.
   --  The entries point to the first names table entry whose hash value
   --  matches the hash code. Then subsequent names table entries with the
   --  same hash code value are linked through the Hash_Link fields.

   package Name_Chars is new GNAT.Table (
     Table_Component_Type => Character,
     Table_Index_Type     => Int,
     Table_Low_Bound      => 0,
     Table_Initial        => Name_Chars_Initial,
     Table_Increment      => Name_Chars_Increment);

   type Name_Entry is record
      Name_Chars_Index : Int;
      --  Starting location of characters in the Name_Chars table minus one
      --  (i.e. pointer to character just before first character). The reason
      --  for the bias of one is that indexes in Name_Buffer are one's origin,
      --  so this avoids unnecessary adds and subtracts of 1.

      Name_Len : Natural;
      --  Length of this name in characters

      Hash_Link : Name_Id;
      --  Link to next entry in names table for same hash code

      Int_Info : Int;
      --  Int Value associated with this name

   end record;

   --  This is the table that is referenced by Name_Id entries.
   --  It contains one entry for each unique name in the table.

   package Name_Entries is new GNAT.Table (
     Table_Component_Type => Name_Entry,
     Table_Index_Type     => Name_Id'Base,
     Table_Low_Bound      => First_Name_Id,
     Table_Initial        => Names_Initial,
     Table_Increment      => Names_Increment);

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
   begin
      for J in S'Range loop
         Add_Char_To_Name_Buffer (S (J));
      end loop;
   end Add_Str_To_Name_Buffer;

   -------------------
   -- Get_Character --
   -------------------

   function Get_Character (C : Char_Code) return Character is
   begin
      pragma Assert (C <= 255);
      return Character'Val (C);
   end Get_Character;

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
      S : Int;

   begin
      pragma Assert (Id in Name_Entries.First .. Name_Entries.Last);

      S := Name_Entries.Table (Id).Name_Chars_Index;
      Name_Len := Name_Entries.Table (Id).Name_Len;

      for J in 1 .. Name_Len loop
         Name_Buffer (J) := Name_Chars.Table (S + Int (J));
      end loop;
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
      S : Int;

   begin
      pragma Assert (Id in Name_Entries.First .. Name_Entries.Last);
      S := Name_Entries.Table (Id).Name_Chars_Index;

      declare
         R : String (1 .. Name_Entries.Table (Id).Name_Len);

      begin
         for J in R'Range loop
            R (J) := Name_Chars.Table (S + Int (J));
         end loop;

         return R;
      end;
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
      S : Int;

   begin
      pragma Assert (Id in Name_Entries.First .. Name_Entries.Last);

      S := Name_Entries.Table (Id).Name_Chars_Index;

      for J in 1 .. Name_Entries.Table (Id).Name_Len loop
         Name_Len := Name_Len + 1;
         Name_Buffer (Name_Len) := Name_Chars.Table (S + Int (J));
      end loop;
   end Get_Name_String_And_Append;

   -------------------------
   -- Get_Name_Table_Int --
   -------------------------

   function Get_Name_Table_Int (Id : Name_Id) return Int is
   begin
      pragma Assert (Id in Name_Entries.First .. Name_Entries.Last);
      return Name_Entries.Table (Id).Int_Info;
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

   --------------------
   -- Length_Of_Name --
   --------------------

   function Length_Of_Name (Id : Name_Id) return Nat is
   begin
      return Int (Name_Entries.Table (Id).Name_Len);
   end Length_Of_Name;

   function Length_Of_Name (Id : File_Name_Type) return Nat is
   begin
      return Int (Name_Entries.Table (Name_Id (Id)).Name_Len);
   end Length_Of_Name;

   ----------------
   -- Name_Enter --
   ----------------

   function Name_Enter return Name_Id is
   begin
      Name_Entries.Append
        ((Name_Chars_Index      => Name_Chars.Last,
          Name_Len              => Name_Len,
          Int_Info              => 0,
          Hash_Link             => No_Name));

      --  Set corresponding string entry in the Name_Chars table

      for J in 1 .. Name_Len loop
         Name_Chars.Append (Name_Buffer (J));
      end loop;

      Name_Chars.Append (ASCII.NUL);

      Last_Id := Name_Entries.Last;

      return Name_Entries.Last;
   end Name_Enter;

   ---------------
   -- Name_Find --
   ---------------

   function Name_Find return Name_Id is
      New_Id : Name_Id;
      --  Id of entry in hash search, and value to be returned

      S : Int;
      --  Pointer into string table

      Hash_Index : Hash_Index_Type;
      --  Computed hash index

   begin
      Hash_Index := Hash;
      New_Id := Hash_Table (Hash_Index);

      if New_Id = No_Name then
         Hash_Table (Hash_Index) := Name_Entries.Last + 1;

      else
         Search : loop
            if Name_Len /=
              Integer (Name_Entries.Table (New_Id).Name_Len)
            then
               goto No_Match;
            end if;

            S := Name_Entries.Table (New_Id).Name_Chars_Index;

            for J in 1 .. Name_Len loop
               if Name_Chars.Table (S + Int (J)) /= Name_Buffer (J) then
                  goto No_Match;
               end if;
            end loop;

            return New_Id;

            --  Current entry in hash chain does not match

            <<No_Match>>
            if Name_Entries.Table (New_Id).Hash_Link /= No_Name then
               New_Id := Name_Entries.Table (New_Id).Hash_Link;
            else
               Name_Entries.Table (New_Id).Hash_Link :=
                 Name_Entries.Last + 1;
               exit Search;
            end if;
         end loop Search;
      end if;

      --  We fall through here only if a matching entry was not found in the
      --  hash table. We now create a new entry in the names table. The hash
      --  link pointing to the new entry (Name_Entries.Last+1) has been set.

      Name_Entries.Append
        ((Name_Chars_Index      => Name_Chars.Last,
          Name_Len              => Name_Len,
          Hash_Link             => No_Name,
          Int_Info              => 0));

      --  Set corresponding string entry in the Name_Chars table

      for J in 1 .. Name_Len loop
         Name_Chars.Append (Name_Buffer (J));
      end loop;

      Name_Chars.Append (ASCII.NUL);

      Last_Id := Name_Entries.Last;

      return Name_Entries.Last;
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

      Actual_Casing : Casing_Type;
      --  Set from C or D as appropriate

      After_Und : Boolean := True;
      --  True at start of string, and after an underline character or after
      --  any other special character that is not a normal identifier char).

   begin
      Actual_Casing := C;

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
            if Actual_Casing = All_Upper_Case
              or else (After_Und and then Actual_Casing = Mixed_Case)
            then
               Name_Buffer (Ptr) := Fold_Upper (Name_Buffer (Ptr));
            end if;

            After_Und := False;
            Ptr := Ptr + 1;

         --  Upper case letter

         elsif Is_Upper_Case_Letter (Name_Buffer (Ptr)) then
            if Actual_Casing = All_Lower_Case
              or else (not After_Und and then Actual_Casing = Mixed_Case)
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
      pragma Assert (Id in Name_Entries.First .. Name_Entries.Last);
      Name_Entries.Table (Id).Int_Info := Val;
   end Set_Name_Table_Int;

   procedure Set_Name_Table_Int (Id : Unit_Name_Type; Val : Int) is
   begin
      Set_Name_Table_Int (Name_Id (Id), Val);
   end Set_Name_Table_Int;

   procedure Set_Name_Table_Int (Id : File_Name_Type; Val : Int) is
   begin
      Set_Name_Table_Int (Name_Id (Id), Val);
   end Set_Name_Table_Int;

   -----------------------------
   -- Store_Encoded_Character --
   -----------------------------

   procedure Store_Encoded_Character (C : Char_Code) is

      procedure Set_Hex_Chars (C : Char_Code);
      --  Stores given value, which is in the range 0 .. 255, as two hex
      --  digits (using lower case a-f) in Name_Buffer, incrementing Name_Len.

      -------------------
      -- Set_Hex_Chars --
      -------------------

      procedure Set_Hex_Chars (C : Char_Code) is
         Hexd : constant String := "0123456789abcdef";
         N    : constant Natural := Natural (C);
      begin
         Name_Buffer (Name_Len + 1) := Hexd (N / 16 + 1);
         Name_Buffer (Name_Len + 2) := Hexd (N mod 16 + 1);
         Name_Len := Name_Len + 2;
      end Set_Hex_Chars;

   --  Start of processing for Store_Encoded_Character

   begin
      Name_Len := Name_Len + 1;

      if In_Character_Range (C) then
         declare
            CC : constant Character := Get_Character (C);
         begin
            if CC in 'a' .. 'z' or else CC in '0' .. '9' then
               Name_Buffer (Name_Len) := CC;
            else
               Name_Buffer (Name_Len) := 'U';
               Set_Hex_Chars (C);
            end if;
         end;

      elsif In_Wide_Character_Range (C) then
         Name_Buffer (Name_Len) := 'W';
         Set_Hex_Chars (C / 256);
         Set_Hex_Chars (C mod 256);

      else
         Name_Buffer (Name_Len) := 'W';
         Name_Len := Name_Len + 1;
         Name_Buffer (Name_Len) := 'W';
         Set_Hex_Chars (C / 2 ** 24);
         Set_Hex_Chars ((C / 2 ** 16) mod 256);
         Set_Hex_Chars ((C / 256) mod 256);
         Set_Hex_Chars (C mod 256);
      end if;
   end Store_Encoded_Character;

   --------
   -- wn --
   --------

   procedure wn2 (Id : Name_Id) is
      S : Int;

   begin
      if not Id'Valid then
         Write_Str ("<invalid name_id>");

      elsif Id = No_Name then
         Write_Str ("<No_Name>");

      elsif Id = Error_Name then
         Write_Str ("<Error_Name>");

      else
         S := Name_Entries.Table (Id).Name_Chars_Index;
         Name_Len := Name_Entries.Table (Id).Name_Len;

         for J in 1 .. Name_Len loop
            Write_Char (Name_Chars.Table (S + Int (J)));
         end loop;
      end if;

      Write_Eol;
   end wn2;

   ----------------
   -- Write_Name --
   ----------------

   procedure Write_Name (Id : Name_Id) is
   begin
      if Id >= First_Name_Id then
         Get_Name_String (Id);
         Write_Str (Name_Buffer (1 .. Name_Len));
      end if;
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

begin
   Name_Chars.Init;
   Name_Entries.Init;

   --  Clear hash table

   for J in Hash_Index_Type loop
      Hash_Table (J) := No_Name;
   end loop;

end GPR.Names;
