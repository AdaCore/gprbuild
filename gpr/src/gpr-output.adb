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

package body GPR.Output is

   Buffer_Max : constant := 32767;
   Buffer : String (1 .. Buffer_Max + 1) := (others => '*');
   for Buffer'Alignment use 4;
   --  Buffer used to build output line.

   Next_Col : Positive range 1 .. Buffer'Length + 1 := 1;
   --  Column about to be written

   Current_FD : File_Descriptor := Standout;
   --  File descriptor for current output

   Special_Output_Proc : Output_Proc := null;
   --  Record argument to last call to Set_Special_Output. If this is
   --  non-null, then we are in special output mode.

   -----------------------
   -- Local_Subprograms --
   -----------------------

   procedure Flush_Buffer;
   --  Flush buffer if non-empty and reset column counter

   procedure Set_Output (FD : File_Descriptor);
   --  Sets subsequent output to appear on the given file descriptor when no
   --  special output is in effect. When a special output is in effect, the
   --  output will appear on the given file descriptor only after special
   --  output has been cancelled.

   ---------------------------
   -- Cancel_Special_Output --
   ---------------------------

   procedure Cancel_Special_Output is
   begin
      Special_Output_Proc := null;
   end Cancel_Special_Output;

   ------------
   -- Column --
   ------------

   function Column return Pos is
   begin
      return Pos (Next_Col);
   end Column;

   ------------------
   -- Flush_Buffer --
   ------------------

   procedure Flush_Buffer is
      Write_Error : exception;
      --  Raised if Write fails

      ------------------
      -- Write_Buffer --
      ------------------

      procedure Write_Buffer (Buf : String);
      --  Write out Buf, either using Special_Output_Proc, or the normal way
      --  using Write. Raise Write_Error if Write fails (presumably due to disk
      --  full). Write_Error is not used in the case of Special_Output_Proc.

      procedure Write_Buffer (Buf : String) is
      begin
         --  If Special_Output_Proc has been set, then use it

         if Special_Output_Proc /= null then
            Special_Output_Proc.all (Buf);

         --  If output is not set, then output to either standard output
         --  or standard error.

         elsif Write (Current_FD, Buf'Address, Buf'Length) /= Buf'Length then
            raise Write_Error;

         end if;
      end Write_Buffer;

      Len : constant Natural := Next_Col - 1;

   --  Start of processing for Flush_Buffer

   begin
      if Len /= 0 then
         begin
            --  If line is too long or if it's a blank line, just write the
            --  buffer.

            Write_Buffer (Buffer (1 .. Len));

         exception
            when Write_Error =>

               --  If there are errors with standard error just quit. Otherwise
               --  set the output to standard error before reporting a failure
               --  and quitting.

               if Current_FD /= Standerr then
                  Current_FD := Standerr;
                  Next_Col := 1;
                  Write_Line ("fatal error: disk full");
               end if;

               OS_Exit (2);
         end;

         --  Buffer is now empty

         Next_Col := 1;
      end if;
   end Flush_Buffer;

   ------------------------
   -- Set_Special_Output --
   ------------------------

   procedure Set_Special_Output (P : Output_Proc) is
   begin
      Special_Output_Proc := P;
   end Set_Special_Output;

   ----------------
   -- Set_Output --
   ----------------

   procedure Set_Output (FD : File_Descriptor) is
   begin
      if Special_Output_Proc = null then
         Flush_Buffer;
      end if;

      Current_FD := FD;
   end Set_Output;

   ------------------------
   -- Set_Standard_Error --
   ------------------------

   procedure Set_Standard_Error is
   begin
      Set_Output (Standerr);
   end Set_Standard_Error;

   -------------------------
   -- Set_Standard_Output --
   -------------------------

   procedure Set_Standard_Output is
   begin
      Set_Output (Standout);
   end Set_Standard_Output;

   ----------------
   -- Write_Char --
   ----------------

   procedure Write_Char (C : Character) is
   begin
      pragma Assert (Next_Col in Buffer'Range);
      if Next_Col = Buffer'Length then
         Write_Eol;
      end if;

      if C = ASCII.LF then
         Write_Eol;
      else
         Buffer (Next_Col) := C;
         Next_Col := Next_Col + 1;
      end if;
   end Write_Char;

   ---------------
   -- Write_Eol --
   ---------------

   procedure Write_Eol is
   begin
      --  Remove any trailing spaces

      while Next_Col > 1 and then Buffer (Next_Col - 1) = ' ' loop
         Next_Col := Next_Col - 1;
      end loop;

      Buffer (Next_Col) := ASCII.LF;
      Next_Col := Next_Col + 1;
      Flush_Buffer;
   end Write_Eol;

   ---------------
   -- Write_Int --
   ---------------

   procedure Write_Int (Val : Int) is
      --  Type Int has one extra negative number (i.e. two's complement), so we
      --  work with negative numbers here. Otherwise, negating Int'First will
      --  overflow.

      subtype Nonpositive is Int range Int'First .. 0;
      procedure Write_Abs (Val : Nonpositive);
      --  Write out the absolute value of Val

      procedure Write_Abs (Val : Nonpositive) is
      begin
         if Val < -9 then
            Write_Abs (Val / 10); -- Recursively write higher digits
         end if;

         Write_Char (Character'Val (-(Val rem 10) + Character'Pos ('0')));
      end Write_Abs;

   begin
      if Val < 0 then
         Write_Char ('-');
         Write_Abs (Val);
      else
         Write_Abs (-Val);
      end if;
   end Write_Int;

   ----------------
   -- Write_Line --
   ----------------

   procedure Write_Line (S : String) is
   begin
      Write_Str (S);
      Write_Eol;
   end Write_Line;

   ---------------
   -- Write_Str --
   ---------------

   procedure Write_Str (S : String) is
   begin
      for J in S'Range loop
         Write_Char (S (J));
      end loop;
   end Write_Str;

end GPR.Output;
