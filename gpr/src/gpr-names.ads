------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2018, Free Software Foundation, Inc.         --
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

package GPR.Names is

   Name_Buffer : String (1 .. 1_000_000);
   Name_Len    : Natural := 0;

   Last_Id     : Name_Id := Name_Id'First;

   procedure Get_Name_String (Id : Name_Id);
   procedure Get_Name_String (Id : Unit_Name_Type);
   procedure Get_Name_String (Id : File_Name_Type);
   procedure Get_Name_String (Id : Path_Name_Type);
   --  Get_Name_String is used to retrieve the string associated with an entry
   --  in the names table. The resulting string is stored in Name_Buffer and
   --  Name_Len is set. It is an error to call Get_Name_String with one of the
   --  special name Id values (No_Name or Error_Name).

   function Get_Name_String (Id : Name_Id) return String;
   function Get_Name_String (Id : Unit_Name_Type) return String;
   function Get_Name_String (Id : File_Name_Type) return String;
   function Get_Name_String (Id : Path_Name_Type) return String;
   --  This functional form returns the result as a string without affecting
   --  the contents of either Name_Buffer or Name_Len. The lower bound is 1.

   procedure Get_Name_String_And_Append (Id : Name_Id);
   --  Like Get_Name_String but the resulting characters are appended to the
   --  current contents of the entry stored in Name_Buffer, and Name_Len is
   --  incremented to include the added characters.

   function Length_Of_Name (Id : Name_Id) return Nat;
   function Length_Of_Name (Id : File_Name_Type) return Nat;
   pragma Inline (Length_Of_Name);

   function Name_Find return Name_Id;
   function Name_Find return Unit_Name_Type;
   function Name_Find return File_Name_Type;
   function Name_Find return Path_Name_Type;

   function Name_Enter return Name_Id;

   procedure Add_Char_To_Name_Buffer (C : Character);
   pragma Inline (Add_Char_To_Name_Buffer);
   --  Add given character to the end of the string currently stored in the
   --  Name_Buffer, incrementing Name_Len.

   procedure Add_Nat_To_Name_Buffer (V : Nat);
   --  Add decimal representation of given value to the end of the string
   --  currently stored in Name_Buffer, incrementing Name_Len as required.

   procedure Add_Str_To_Name_Buffer (S : String);
   --  Add characters of string S to the end of the string currently stored in
   --  the Name_Buffer, incrementing Name_Len by the length of the string.

   function Get_Name_Table_Int (Id : Name_Id) return Int;
   function Get_Name_Table_Int (Id : Unit_Name_Type) return Int;
   function Get_Name_Table_Int (Id : File_Name_Type) return Int;
   pragma Inline (Get_Name_Table_Int);
   --  Fetches the Int value associated with the given name

   procedure Set_Name_Table_Int (Id : Name_Id; Val : Int);
   procedure Set_Name_Table_Int (Id : Unit_Name_Type; Val : Int);
   procedure Set_Name_Table_Int (Id : File_Name_Type; Val : Int);
   pragma Inline (Set_Name_Table_Int);
   --  Sets the Int value associated with the given name

   type Char_Code_Base is mod 2 ** 32;
   for Char_Code_Base'Size use 32;

   subtype Char_Code is Char_Code_Base range 0 .. 16#7FFF_FFFF#;
   for Char_Code'Value_Size use 32;
   for Char_Code'Object_Size use 32;

   function Get_Char_Code (C : Character) return Char_Code;
   pragma Inline (Get_Char_Code);
   --  Function to obtain internal character code from source character. For
   --  the moment, the internal character code is simply the Pos value of the
   --  input source character, but we provide this interface for possible later
   --  support of alternative character sets.

   function In_Character_Range (C : Char_Code) return Boolean;
   pragma Inline (In_Character_Range);
   --  Determines if the given character code is in range of type Character,
   --  and if so, returns True. If not, returns False.

   function Get_Character (C : Char_Code) return Character;
   pragma Inline (Get_Character);
   --  For a character C that is in Character range (see above function), this
   --  function returns the corresponding Character value. It is an error to
   --  call Get_Character if C is not in Character range.

   procedure Store_Encoded_Character (C : Char_Code);
   --  Stores given character code at the end of Name_Buffer, updating the
   --  value in Name_Len appropriately. Lower case letters and digits are
   --  stored unchanged. Other 8-bit characters are stored using the Uhh
   --  encoding (hh = hex code), other 16-bit wide character values are stored
   --  using the Whhhh (hhhh = hex code) encoding, and other 32-bit wide wide
   --  character values are stored using the WWhhhhhhhh (hhhhhhhh = hex code).
   --  Note that this procedure does not fold upper case letters (they are
   --  stored using the Uhh encoding). If folding is required, it must be
   --  done by the caller prior to the call.

   procedure Write_Name (Id : Name_Id);
   procedure Write_Name (Id : File_Name_Type);
   procedure Write_Name (Id : Path_Name_Type);
   --  Write_Name writes the characters of the specified name Id to the
   --  specific file File. No end of line is written, just the characters of
   --  the name. On return Name_Buffer and Name_Len are set as for a call to
   --  Get_Name_String. The name is written in encoded form (i.e. including
   --  Uhh, Whhh, Qx, _op as they appear in the name table). If Id is
   --  Error_Name, or No_Name, no text is output.

   procedure Write_Unit_Name (U : Unit_Name_Type);
   --  Output unit name with (body) or (spec) after as required.

   ------------------------
   -- Debugging Routines --
   ------------------------

   procedure wn2 (Id : Name_Id);
   pragma Export (Ada, wn2);

   -------------------------------
   -- Case Control Declarations --
   -------------------------------

   --  Declaration of type for describing casing convention

   type Casing_Type is
     (All_Upper_Case,
      --  All letters are upper case

      All_Lower_Case,
      --  All letters are lower case

      Mixed_Case,
      --  The initial letter, and any letters after underlines are upper case.
      --  All other letters are lower case

      Unknown
      --  Used if an identifier does not distinguish between the above cases,
      --  (e.g. X, Y_3, M4, A_B, or if it is inconsistent ABC_def).
     );

   subtype Known_Casing is Casing_Type range All_Upper_Case .. Mixed_Case;
   --  Exclude Unknown casing

   procedure Set_Casing (C : Casing_Type);
   --  Takes the name stored in the first Name_Len positions of Name_Buffer and
   --  modifies it to be consistent with the casing given by C.

end GPR.Names;
