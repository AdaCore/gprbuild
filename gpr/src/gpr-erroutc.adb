------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 1992-2020, Free Software Foundation, Inc.         --
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

with Interfaces; use Interfaces;

pragma Warnings (Off);
with System.WCh_Con; use System.WCh_Con;
pragma Warnings (On);

with GPR.Names;  use GPR.Names;
with GPR.Opt;    use GPR.Opt;
with GPR.Output; use GPR.Output;
with GPR.Sinput; use GPR.Sinput;

package body GPR.Erroutc is

   type UTF_32_Code is range 0 .. 16#7FFF_FFFF#;
   for UTF_32_Code'Size use 32;
   --  Range of allowed UTF-32 encoding values

   function Same_Error (M1, M2 : Error_Msg_Id) return Boolean;
   --  See if two messages have the same text. Returns true if the text of the
   --  two messages is identical, or if one of them is the same as the other
   --  with an appended "instance at xxx" tag.

   procedure Set_Msg_Blank;
   --  Sets a single blank in the message if the preceding character is a
   --  non-blank character other than a left parenthesis or minus. Has no
   --  effect if manual quote mode is turned on.

   procedure Set_Msg_Blank_Conditional;
   --  Sets a single blank in the message if the preceding character is a
   --  non-blank character other than a left parenthesis or quote. Has no
   --  effect if manual quote mode is turned on.

   procedure Set_Msg_Name_Buffer;
   --  Output name from Name_Buffer, with surrounding quotes unless manual
   --  quotation mode is in effect.

   procedure Set_Msg_Quote;
   --  Set quote if in normal quote mode, nothing if in manual quote mode

   procedure Set_Next_Non_Deleted_Msg (E : in out Error_Msg_Id);
   --  Given a message id, move to next message id, but skip any deleted
   --  messages, so that this results in E on output being the first non-
   --  deleted message following the input value of E, or No_Error_Msg if
   --  the input value of E was either already No_Error_Msg, or was the
   --  last non-deleted message.

   procedure Skip_Wide (S : Source_Buffer_Ptr; P : in out Source_Ptr);
   --  Similar to the above procedure, but operates on a source buffer
   --  instead of a string, with P being a Source_Ptr referencing the
   --  contents of the source buffer.

   procedure Write_Spaces (N : Nat);
   --  Write N spaces

   -----------------------------
   -- Check_Duplicate_Message --
   -----------------------------

   procedure Check_Duplicate_Message (M1, M2 : Error_Msg_Id) is
      L1, L2 : Error_Msg_Id;
      N1, N2 : Error_Msg_Id;

      procedure Delete_Msg (Delete, Keep : Error_Msg_Id);
      --  Called to delete message Delete, keeping message Keep. Marks msg
      --  Delete and all its continuations with deleted flag set to True.
      --  Also makes sure that for the error messages that are retained the
      --  preferred message is the one retained (we prefer the shorter one in
      --  the case where one has an Instance tag). Note that we always know
      --  that Keep has at least as many continuations as Delete (since we
      --  always delete the shorter sequence).

      ----------------
      -- Delete_Msg --
      ----------------

      procedure Delete_Msg (Delete, Keep : Error_Msg_Id) is
         D, K : Error_Msg_Id;

      begin
         D := Delete;
         K := Keep;

         loop
            Errors.Table (D).Deleted := True;

            --  Adjust error message count

            if Errors.Table (D).Warn then
               Warnings_Detected := Warnings_Detected - 1;

               if Errors.Table (D).Info then
                  Info_Messages := Info_Messages - 1;
               end if;

               --  Note: we do not need to decrement Warnings_Treated_As_Errors
               --  because this only gets incremented if we actually output the
               --  message, which we won't do if we are deleting it here!

            else
               Total_Errors_Detected := Total_Errors_Detected - 1;

               if Errors.Table (D).Serious then
                  Serious_Errors_Detected := Serious_Errors_Detected - 1;
               end if;
            end if;

            --  Substitute shorter of the two error messages

            if Errors.Table (K).Text'Length > Errors.Table (D).Text'Length then
               Errors.Table (K).Text := Errors.Table (D).Text;
            end if;

            D := Errors.Table (D).Next;
            K := Errors.Table (K).Next;

            if D = No_Error_Msg or else not Errors.Table (D).Msg_Cont then
               return;
            end if;
         end loop;
      end Delete_Msg;

   --  Start of processing for Check_Duplicate_Message

   begin
      --  Both messages must be non-continuation messages and not deleted

      if Errors.Table (M1).Msg_Cont
        or else Errors.Table (M2).Msg_Cont
        or else Errors.Table (M1).Deleted
        or else Errors.Table (M2).Deleted
      then
         return;
      end if;

      --  Definitely not equal if message text does not match

      if not Same_Error (M1, M2) then
         return;
      end if;

      --  Same text. See if all continuations are also identical

      L1 := M1;
      L2 := M2;

      loop
         N1 := Errors.Table (L1).Next;
         N2 := Errors.Table (L2).Next;

         --  If M1 continuations have run out, we delete M1, either the
         --  messages have the same number of continuations, or M2 has
         --  more and we prefer the one with more anyway.

         if N1 = No_Error_Msg or else not Errors.Table (N1).Msg_Cont then
            Delete_Msg (M1, M2);
            return;

         --  If M2 continuations have run out, we delete M2

         elsif N2 = No_Error_Msg or else not Errors.Table (N2).Msg_Cont then
            Delete_Msg (M2, M1);
            return;

         --  Otherwise see if continuations are the same, if not, keep both
         --  sequences, a curious case, but better to keep everything.

         elsif not Same_Error (N1, N2) then
            return;

         --  If continuations are the same, continue scan

         else
            L1 := N1;
            L2 := N2;
         end if;
      end loop;
   end Check_Duplicate_Message;

   ------------------------
   -- Compilation_Errors --
   ------------------------

   function Compilation_Errors return Boolean is
   begin
      return Total_Errors_Detected /= 0
        or else (Warnings_Detected - Info_Messages /= 0
                  and then Warning_Mode = Treat_As_Error)
        or else Warnings_Treated_As_Errors /= 0;
   end Compilation_Errors;

   ------------------
   -- Get_Location --
   ------------------

   function Get_Location (E : Error_Msg_Id) return Source_Ptr is
   begin
      return Errors.Table (E).Sptr;
   end Get_Location;

   ----------------
   -- Get_Msg_Id --
   ----------------

   function Get_Msg_Id return Error_Msg_Id is
   begin
      return Cur_Msg;
   end Get_Msg_Id;

   ---------------------------
   -- Is_Start_Of_Wide_Char --
   ---------------------------

   function Is_Start_Of_Wide_Char
     (S : Source_Buffer_Ptr;
      P : Source_Ptr) return Boolean
   is
   begin
      case Wide_Character_Encoding_Method is

         --  For Hex mode, just test for an ESC character. The ESC character
         --  cannot appear in any other context in a legal Ada program.

         when WCEM_Hex =>
            return S (P) = ASCII.ESC;

         --  For brackets, just test ["x where x is a hex character. This is
         --  sufficient test, since this sequence cannot otherwise appear in a
         --  legal Ada program.

         when WCEM_Brackets =>
            return P <= S'Last - 2
              and then S (P) = '['
              and then S (P + 1) = '"'
              and then (S (P + 2) in '0' .. '9'
                            or else
                           S (P + 2) in 'a' .. 'f'
                            or else
                        S (P + 2) in 'A' .. 'F');

         --  All other encoding methods use the upper bit set in the first
         --  character to uniquely represent a wide character.

         when WCEM_Upper     |
              WCEM_Shift_JIS |
              WCEM_EUC       |
              WCEM_UTF8      =>
            return S (P) >= Character'Val (16#80#);
      end case;
   end Is_Start_Of_Wide_Char;

   -----------------------
   -- Output_Error_Msgs --
   -----------------------

   procedure Output_Error_Msgs (E : in out Error_Msg_Id) is
      P : Source_Ptr;
      T : Error_Msg_Id;
      S : Error_Msg_Id;

      Flag_Num   : Pos;
      Mult_Flags : Boolean := False;

   begin
      S := E;

      --  Figure out if we will place more than one error flag on this line

      T := S;
      while T /= No_Error_Msg
        and then Errors.Table (T).Line = Errors.Table (E).Line
        and then Errors.Table (T).Sfile = Errors.Table (E).Sfile
      loop
         if Errors.Table (T).Sptr > Errors.Table (E).Sptr then
            Mult_Flags := True;
         end if;

         Set_Next_Non_Deleted_Msg (T);
      end loop;

      --  Output the error flags. The circuit here makes sure that the tab
      --  characters in the original line are properly accounted for. The
      --  eight blanks at the start are to match the line number.

      Write_Str ("        ");
      P := Line_Start (Errors.Table (E).Sptr);

      if P = No_Location then
         return;
      end if;

      Flag_Num := 1;

      --  Loop through error messages for this line to place flags

      T := S;
      while T /= No_Error_Msg
        and then Errors.Table (T).Line = Errors.Table (E).Line
        and then Errors.Table (T).Sfile = Errors.Table (E).Sfile
      loop
         declare
            Src : Source_Buffer_Ptr
            renames Source_Text (Errors.Table (T).Sfile);

         begin
            --  Loop to output blanks till current flag position

            while P < Errors.Table (T).Sptr loop

               --  Horizontal tab case, just echo the tab

               if Src (P) = ASCII.HT then
                  Write_Char (ASCII.HT);
                  P := P + 1;

                  --  Deal with wide character case, but don't include brackets
                  --  notation in this circuit, since we know that this will
                  --  display unencoded (no one encodes brackets notation).

               elsif Src (P) /= '['
                 and then Is_Start_Of_Wide_Char (Src, P)
               then
                  Skip_Wide (Src, P);
                  Write_Char (' ');

                  --  Normal non-wide character case (or bracket)

               else
                  P := P + 1;
                  Write_Char (' ');
               end if;
            end loop;

            --  Output flag (unless already output, this happens if more
            --  than one error message occurs at the same flag position).

            if P = Errors.Table (T).Sptr then
               Write_Char
                 ((if
                     (Flag_Num = 1 and then not Mult_Flags)
                     or else Flag_Num > 9
                   then '|'
                   else Character'Val (Character'Pos ('0') + Flag_Num)));

               --  Skip past the corresponding source text character

               --  Horizontal tab case, we output a flag at the tab position
               --  so now we output a tab to match up with the text.

               if Src (P) = ASCII.HT then
                  Write_Char (ASCII.HT);
                  P := P + 1;

                  --  Skip wide character other than left bracket

               elsif Src (P) /= '['
                 and then Is_Start_Of_Wide_Char (Src, P)
               then
                  Skip_Wide (Src, P);

                  --  Skip normal non-wide character case (or bracket)

               else
                  P := P + 1;
               end if;
            end if;
         end;

         Set_Next_Non_Deleted_Msg (T);
         Flag_Num := Flag_Num + 1;
      end loop;

      Write_Eol;

      --  Now output the error messages

      T := S;
      while T /= No_Error_Msg
        and then Errors.Table (T).Line = Errors.Table (E).Line
        and then Errors.Table (T).Sfile = Errors.Table (E).Sfile
      loop
         Write_Str ("        >>> ");
         Output_Msg_Text (T);

         Write_Eol;
         Set_Next_Non_Deleted_Msg (T);
      end loop;

      E := T;
   end Output_Error_Msgs;

   ------------------------
   -- Output_Line_Number --
   ------------------------

   procedure Output_Line_Number (L : Line_Number) is
      D     : Int;       -- next digit
      C     : Character; -- next character
      Z     : Boolean;   -- flag for zero suppress
      N, M  : Int;       -- temporaries

   begin
      if L = No_Line_Number then
         Write_Str ("        ");

      else
         Z := False;
         N := Int (L);

         M := 100_000;
         while M /= 0 loop
            D := Int (N / M);
            N := N rem M;
            M := M / 10;

            if D = 0 then
               C := (if Z then '0' else ' ');
            else
               Z := True;
               C := Character'Val (D + 48);
            end if;

            Write_Char (C);
         end loop;

         Write_Str (". ");
      end if;
   end Output_Line_Number;

   ---------------------
   -- Output_Msg_Text --
   ---------------------

   procedure Output_Msg_Text (E : Error_Msg_Id) is
      Offs : constant Nat := Column - 1;
      --  Offset to start of message, used for continuations

      Txt  : constant String := Errors.Table (E).Text.all;

      procedure Write_Text (Txt : String);
      --  Write the message, splitting it up into multiple lines

      ----------------
      -- Write_Text --
      ----------------

      procedure Write_Text (Txt : String) is
      begin
         for J in 1 .. Txt'Length loop
            if Txt (J) = ASCII.LF then
               Write_Eol;
               Write_Spaces (Offs);
            else
               Write_Char (Txt (J));
            end if;
         end loop;
      end Write_Text;

   begin
      --  Deal with warning case

      if Errors.Table (E).Warn then

         --  For info messages, prefix message with "info: "

         if Errors.Table (E).Info then
            Write_Text ("info: " & Txt);

            --  Warning treated as error

         elsif Errors.Table (E).Warn_Err then

            --  We prefix with "error:" rather than warning: and postfix
            --  [warning-as-error] at the end.

            Warnings_Treated_As_Errors := Warnings_Treated_As_Errors + 1;
            Write_Text ("error: " & Txt & " [warning-as-error]");

            --  Normal case, prefix with "warning: "

         else
            Write_Text ("warning: " & Txt);
         end if;
      else
         Write_Text (Txt);
      end if;
   end Output_Msg_Text;

   ----------------
   -- Same_Error --
   ----------------

   function Same_Error (M1, M2 : Error_Msg_Id) return Boolean is
      Msg1 : constant String_Access := Errors.Table (M1).Text;
      Msg2 : constant String_Access := Errors.Table (M2).Text;

      Msg2_Len : constant Integer := Msg2'Length;
      Msg1_Len : constant Integer := Msg1'Length;

   begin
      return
        Msg1.all = Msg2.all
          or else
            (Msg1_Len - 10 > Msg2_Len
               and then
             Msg2.all = Msg1.all (1 .. Msg2_Len)
               and then
             Msg1 (Msg2_Len + 1 .. Msg2_Len + 10) = ", instance")
          or else
            (Msg2_Len - 10 > Msg1_Len
               and then
             Msg1.all = Msg2.all (1 .. Msg1_Len)
               and then
             Msg2 (Msg1_Len + 1 .. Msg1_Len + 10) = ", instance");
   end Same_Error;

   -------------------
   -- Set_Msg_Blank --
   -------------------

   procedure Set_Msg_Blank is
   begin
      if Msglen > 0
        and then Msg_Buffer (Msglen) /= ' '
        and then Msg_Buffer (Msglen) /= '('
        and then Msg_Buffer (Msglen) /= '-'
        and then not Manual_Quote_Mode
      then
         Set_Msg_Char (' ');
      end if;
   end Set_Msg_Blank;

   -------------------------------
   -- Set_Msg_Blank_Conditional --
   -------------------------------

   procedure Set_Msg_Blank_Conditional is
   begin
      if Msglen > 0
        and then Msg_Buffer (Msglen) /= ' '
        and then Msg_Buffer (Msglen) /= '('
        and then Msg_Buffer (Msglen) /= '"'
        and then not Manual_Quote_Mode
      then
         Set_Msg_Char (' ');
      end if;
   end Set_Msg_Blank_Conditional;

   ------------------
   -- Set_Msg_Char --
   ------------------

   procedure Set_Msg_Char (C : Character) is
   begin

      --  The check for message buffer overflow is needed to deal with cases
      --  where insertions get too long (in particular a child unit name can
      --  be very long).

      if Msglen < Max_Msg_Length then
         Msglen := Msglen + 1;
         Msg_Buffer (Msglen) := C;
      end if;
   end Set_Msg_Char;

   ---------------------------------
   -- Set_Msg_Insertion_File_Name --
   ---------------------------------

   procedure Set_Msg_Insertion_File_Name is
   begin
      if Error_Msg_File_1 = No_File then
         null;

      elsif Error_Msg_File_1 = Error_File_Name then
         Set_Msg_Blank;
         Set_Msg_Str ("<error>");

      else
         Set_Msg_Blank;
         Get_Name_String (Error_Msg_File_1);
         Set_Msg_Quote;
         Set_Msg_Name_Buffer;
         Set_Msg_Quote;
      end if;

      --  The following assignments ensure that the second { insertion
      --  characters will correspond to the Error_Msg_File_2.

      Error_Msg_File_1 := Error_Msg_File_2;
   end Set_Msg_Insertion_File_Name;

   ----------------------------
   -- Set_Msg_Insertion_Name --
   ----------------------------

   procedure Set_Msg_Insertion_Name is
   begin
      if Error_Msg_Name_1 = No_Name then
         null;

      elsif Error_Msg_Name_1 = Error_Name then
         Set_Msg_Blank;
         Set_Msg_Str ("<error>");

      else
         Set_Msg_Blank_Conditional;
         Get_Name_String (Error_Msg_Name_1);

         --  Remove upper case letter at end, again, we should not be getting
         --  such names, and what we hope is that the remainder makes sense.

         if Name_Len > 1 and then Name_Buffer (Name_Len) in 'A' .. 'Z' then
            Name_Len := Name_Len - 1;
         end if;

         --  If operator name or character literal name, just print it as is
         --  Also print as is if it ends in a right paren (case of x'val(nnn))

         if Name_Buffer (1) = '"'
           or else Name_Buffer (1) = '''
           or else Name_Buffer (Name_Len) = ')'
         then
            Set_Msg_Name_Buffer;

         --  Else output with surrounding quotes in proper casing mode

         else
            Set_Casing (Mixed_Case);
            Set_Msg_Quote;
            Set_Msg_Name_Buffer;
            Set_Msg_Quote;
         end if;
      end if;

      Error_Msg_Name_1 := Error_Msg_Name_2;
   end Set_Msg_Insertion_Name;

   ------------------------------------
   -- Set_Msg_Insertion_Name_Literal --
   ------------------------------------

   procedure Set_Msg_Insertion_Name_Literal is
   begin
      if Error_Msg_Name_1 = No_Name then
         null;

      elsif Error_Msg_Name_1 = Error_Name then
         Set_Msg_Blank;
         Set_Msg_Str ("<error>");

      else
         Set_Msg_Blank;
         Get_Name_String (Error_Msg_Name_1);
         Set_Msg_Quote;
         Set_Msg_Name_Buffer;
         Set_Msg_Quote;
      end if;

      Error_Msg_Name_1 := Error_Msg_Name_2;
   end Set_Msg_Insertion_Name_Literal;

   -------------------------------------
   -- Set_Msg_Insertion_Reserved_Name --
   -------------------------------------

   procedure Set_Msg_Insertion_Reserved_Name is
   begin
      Set_Msg_Blank_Conditional;
      Get_Name_String (Error_Msg_Name_1);
      Set_Msg_Quote;
      Set_Casing (All_Lower_Case);
      Set_Msg_Name_Buffer;
      Set_Msg_Quote;
   end Set_Msg_Insertion_Reserved_Name;

   -------------------------------------
   -- Set_Msg_Insertion_Reserved_Word --
   -------------------------------------

   procedure Set_Msg_Insertion_Reserved_Word
     (Text : String;
      J    : in out Integer)
   is
   begin
      Set_Msg_Blank_Conditional;
      Name_Len := 0;

      while J <= Text'Last and then Text (J) in 'A' .. 'Z' loop
         Add_Char_To_Name_Buffer (Text (J));
         J := J + 1;
      end loop;

      --  Here is where we make the special exception for RM

      if Name_Len = 2 and then Name_Buffer (1 .. 2) = "RM" then
         Set_Msg_Name_Buffer;

      --  We make a similar exception for SPARK

      elsif Name_Len = 5 and then Name_Buffer (1 .. 5) = "SPARK" then
         Set_Msg_Name_Buffer;

      --  Neither RM nor SPARK: case appropriately and add surrounding quotes

      else
         Set_Casing (All_Lower_Case);
         Set_Msg_Quote;
         Set_Msg_Name_Buffer;
         Set_Msg_Quote;
      end if;
   end Set_Msg_Insertion_Reserved_Word;

   -------------------------
   -- Set_Msg_Name_Buffer --
   -------------------------

   procedure Set_Msg_Name_Buffer is
   begin
      Set_Msg_Str (Name_Buffer (1 .. Name_Len));
   end Set_Msg_Name_Buffer;

   -------------------
   -- Set_Msg_Quote --
   -------------------

   procedure Set_Msg_Quote is
   begin
      if not Manual_Quote_Mode then
         Set_Msg_Char ('"');
      end if;
   end Set_Msg_Quote;

   -----------------
   -- Set_Msg_Str --
   -----------------

   procedure Set_Msg_Str (Text : String) is
   begin
      for J in Text'Range loop
         Set_Msg_Char (Text (J));
      end loop;
   end Set_Msg_Str;

   ------------------------------
   -- Set_Next_Non_Deleted_Msg --
   ------------------------------

   procedure Set_Next_Non_Deleted_Msg (E : in out Error_Msg_Id) is
   begin
      if E = No_Error_Msg then
         return;

      else
         loop
            E := Errors.Table (E).Next;
            exit when E = No_Error_Msg or else not Errors.Table (E).Deleted;
         end loop;
      end if;
   end Set_Next_Non_Deleted_Msg;

   ---------------
   -- Skip_Wide --
   ---------------

   procedure Skip_Wide (S : Source_Buffer_Ptr; P : in out Source_Ptr) is
      B1 : Unsigned_32;
      C1 : Character;
      U  : Unsigned_32;
      W  : Unsigned_32;

      procedure Get_Hex (N : Character);
      --  If N is a hex character, then set B1 to 16 * B1 + character N.
      --  Raise Constraint_Error if character N is not a hex character.

      procedure Get_UTF_Byte;
      pragma Inline (Get_UTF_Byte);
      --  Used to interpret a 2#10xxxxxx# continuation byte in UTF-8 mode.
      --  Reads a byte, and raises CE if the first two bits are not 10.
      --  Otherwise shifts W 6 bits left and or's in the 6 xxxxxx bits.

      function Skip_Char return Character;
      --  Function to skip one character of wide character escape sequence

      -------------
      -- Get_Hex --
      -------------

      procedure Get_Hex (N : Character) is
         B2 : constant Unsigned_32 := Character'Pos (N);
      begin
         if B2 in Character'Pos ('0') .. Character'Pos ('9') then
            B1 := B1 * 16 + B2 - Character'Pos ('0');
         elsif B2 in Character'Pos ('A') .. Character'Pos ('F') then
            B1 := B1 * 16 + B2 - (Character'Pos ('A') - 10);
         elsif B2 in Character'Pos ('a') .. Character'Pos ('f') then
            B1 := B1 * 16 + B2 - (Character'Pos ('a') - 10);
         else
            raise Constraint_Error;
         end if;
      end Get_Hex;

      ------------------
      -- Get_UTF_Byte --
      ------------------

      procedure Get_UTF_Byte is
      begin
         U := Unsigned_32 (Character'Pos (Skip_Char));

         if (U and 2#11000000#) /= 2#10_000000# then
            raise Constraint_Error;
         end if;

         W := Shift_Left (W, 6) or (U and 2#00111111#);
      end Get_UTF_Byte;

      ---------------
      -- Skip_Char --
      ---------------

      function Skip_Char return Character is
      begin
         P := P + 1;
         return S (P - 1);
      end Skip_Char;

   --  Start of processing for Skip_Wide

      C : constant Character := Skip_Char;

   begin
      case Wide_Character_Encoding_Method is

         when WCEM_Hex =>
            if C /= ASCII.ESC then
               null;

            else
               B1 := 0;
               Get_Hex (Skip_Char);
               Get_Hex (Skip_Char);
               Get_Hex (Skip_Char);
               Get_Hex (Skip_Char);
            end if;

         when WCEM_Upper | WCEM_Shift_JIS | WCEM_EUC =>
            null;

         when WCEM_UTF8 =>

            --  Note: for details of UTF8 encoding see RFC 3629

            U := Unsigned_32 (Character'Pos (C));

            --  16#00_0000#-16#00_007F#: 0xxxxxxx

            if (U and 2#10000000#) = 2#00000000# then
               null;

            --  16#00_0080#-16#00_07FF#: 110xxxxx 10xxxxxx

            elsif (U and 2#11100000#) = 2#110_00000# then
               Get_UTF_Byte;

            --  16#00_0800#-16#00_ffff#: 1110xxxx 10xxxxxx 10xxxxxx

            elsif (U and 2#11110000#) = 2#1110_0000# then
               Get_UTF_Byte;
               Get_UTF_Byte;

            --  16#01_0000#-16#10_FFFF#: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx

            elsif (U and 2#11111000#) = 2#11110_000# then
               for K in 1 .. 3 loop
                  Get_UTF_Byte;
               end loop;

            --  16#0020_0000#-16#03FF_FFFF#: 111110xx 10xxxxxx 10xxxxxx
            --                               10xxxxxx 10xxxxxx

            elsif (U and 2#11111100#) = 2#111110_00# then
               for K in 1 .. 4 loop
                  Get_UTF_Byte;
               end loop;

            --  16#0400_0000#-16#7FFF_FFFF#: 1111110x 10xxxxxx 10xxxxxx
            --                               10xxxxxx 10xxxxxx 10xxxxxx

            elsif (U and 2#11111110#) = 2#1111110_0# then
               for K in 1 .. 5 loop
                  Get_UTF_Byte;
               end loop;

            else
               raise Constraint_Error;
            end if;

         when WCEM_Brackets =>
            if C = '[' then
               if Skip_Char /= '"' then
                  raise Constraint_Error;
               end if;

               B1 := 0;
               Get_Hex (Skip_Char);
               Get_Hex (Skip_Char);

               C1 := Skip_Char;

               if C1 /= '"' then
                  Get_Hex (C1);
                  Get_Hex (Skip_Char);

                  C1 := Skip_Char;

                  if C1 /= '"' then
                     Get_Hex (C1);
                     Get_Hex (Skip_Char);

                     C1 := Skip_Char;

                     if C1 /= '"' then
                        Get_Hex (C1);
                        Get_Hex (Skip_Char);

                        if B1 > Unsigned_32 (UTF_32_Code'Last) then
                           raise Constraint_Error;
                        end if;

                        if Skip_Char /= '"' then
                           raise Constraint_Error;
                        end if;
                     end if;
                  end if;
               end if;

               if Skip_Char /= ']' then
                  raise Constraint_Error;
               end if;
            end if;
      end case;
   end Skip_Wide;

   ------------------
   -- Write_Spaces --
   ------------------

   procedure Write_Spaces (N : Nat) is
   begin
      for J in 1 .. N loop
         Write_Char (' ');
      end loop;
   end Write_Spaces;

end GPR.Erroutc;
