------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2016-2018, Free Software Foundation, Inc.         --
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

with GPR.Names; use GPR.Names;

package body GPR.Script is

   Quote_List : constant String := "|&;<>()$`\"" *?[#~";

   function Potentially_Quoted (S : String) return String;
   --  Check if S needed to be quoted. It needs to be quoted if S contains at
   --  least one character in the list above. Return S between simple quotes if
   --  needed, otherwise return S.

   ------------------------
   -- Potentially_Quoted --
   ------------------------

   function Potentially_Quoted (S : String) return String is
      Need_Quoting : Boolean := False;
      Arg : String (1 .. 4 * S'Length);
      Last : Natural := 0;

   begin
      for J in S'Range loop
         if S (J) = ''' then
            Need_Quoting := True;
            Arg (Last + 1 .. Last + 4) := "'\''";
            Last := Last + 4;

         else
            Last := Last + 1;
            Arg (Last) := S (J);

            if not Need_Quoting then
               for K in Quote_List'Range loop
                  if S (J) = Quote_List (K) then
                     Need_Quoting := True;
                     exit;
                  end if;
               end loop;
            end if;
         end if;
      end loop;

      return (if Need_Quoting then "'" & Arg (1 .. Last) & "'" else S);
   end Potentially_Quoted;

   -----------------------
   -- Script_Change_Dir --
   -----------------------

   procedure Script_Change_Dir (New_Dir : Path_Name_Type)
   is
      Args : String_Vectors.Vector;
   begin
      if Build_Script_Name = null then
         return;
      end if;

      Args.Append (Get_Name_String (New_Dir));
      Script_Write ("cd", Args);
   end Script_Change_Dir;

   -----------------
   -- Script_Copy --
   -----------------

   procedure Script_Copy
     (File_Name   : String;
      Destination : String)
   is
   begin
      if Build_Script_Name = null then
         return;
      end if;

      declare
         Args : String_Vectors.Vector;
      begin
         Args.Append (File_Name);
         Args.Append (Destination);

         Script_Write ("cp", Args);
      end;
   end Script_Copy;

   ------------------
   -- Script_Write --
   ------------------

   procedure Script_Write
     (Program_Name : String;
      Args         : String_Vectors.Vector)
   is
      Already_Open : Boolean;
   begin
      if Build_Script_Name = null then
         return;
      end if;

      Already_Open := Is_Open (Build_Script_File);

      if not Already_Open then
         Open (Build_Script_File, Append_File, Build_Script_Name.all);
      end if;

      Put (Build_Script_File, Potentially_Quoted (Program_Name));

      for Arg of Args loop
         Put
           (Build_Script_File,
            " " & Potentially_Quoted (Arg));
      end loop;

      New_Line (Build_Script_File);

      if not Already_Open then
         Close (Build_Script_File);
      end if;
   end Script_Write;

   ----------------------------
   -- Spawn_And_Script_Write --
   ----------------------------

   procedure Spawn_And_Script_Write
     (Program_Name : String;
      Args         : String_Vectors.Vector;
      Success      : out Boolean)
   is
      Arg_List : String_List_Access :=
                   new String_List'(To_Argument_List (Args));
   begin
      Script_Write (Program_Name, Args);
      Spawn (Program_Name, Arg_List.all, Success);
      Free (Arg_List);
   end Spawn_And_Script_Write;

end GPR.Script;
