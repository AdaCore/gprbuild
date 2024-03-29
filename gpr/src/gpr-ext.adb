------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2000-2022, Free Software Foundation, Inc.         --
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

with Ada.Unchecked_Deallocation;

with GPR.Names; use GPR.Names;
with GPR.Osint; use GPR.Osint;

package body GPR.Ext is

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Self      : out External_References;
      Copy_From : External_References := No_External_Refs)
   is
      N  : Name_To_Name_Ptr;
      N2 : Name_To_Name_Ptr;
   begin
      if Self.Refs = null then
         Self.Refs := new Name_To_Name_HTable.Instance;

         if Copy_From.Refs /= null then
            N := Name_To_Name_HTable.Get_First (Copy_From.Refs.all);
            while N /= null loop
               N2 := new Name_To_Name'
                           (Key    => N.Key,
                            Value  => N.Value,
                            Source => N.Source,
                            Next   => null);
               Name_To_Name_HTable.Set (Self.Refs.all, N2);
               N := Name_To_Name_HTable.Get_Next (Copy_From.Refs.all);
            end loop;
         end if;
      end if;

      if Self.Context = null then
         Self.Context := new Context;
      end if;

   end Initialize;

   ---------
   -- Add --
   ---------

   procedure Add
     (Self          : External_References;
      External_Name : String;
      Value         : String;
      Source        : External_Source := External_Source'First;
      Silent        : Boolean := False)
   is
      Key : Name_Id;
      N   : Name_To_Name_Ptr;

   begin
      --  For external attribute, set the environment variable

      if Source = From_External_Attribute and then External_Name /= "" then
         declare
            Env_Var : String_Access := Getenv (External_Name);

         begin
            if Env_Var = null or else Env_Var.all = "" then
               Setenv (Name => External_Name, Value => Value);

               if not Silent then
                  Debug_Output
                    ("Environment variable """ & External_Name
                     & """ = """ & Value & '"');
               end if;

            elsif not Silent then
               Debug_Output
                 ("Not overriding existing environment variable """
                  & External_Name & """, value is """ & Env_Var.all & '"');
            end if;

            Free (Env_Var);
         end;
      end if;

      Name_Len := External_Name'Length;
      Name_Buffer (1 .. Name_Len) := External_Name;
      Canonical_Case_Env_Var_Name (Name_Buffer (1 .. Name_Len));
      Key := Name_Find;

      --  Check whether the value is already defined, to properly respect the
      --  overriding order.

      if Source /= External_Source'First then
         N := Name_To_Name_HTable.Get (Self.Refs.all, Key);

         if N /= null then
            if External_Source'Pos (N.Source) <
               External_Source'Pos (Source)
            then
               if not Silent then
                  Debug_Output
                    ("Not overriding existing external reference '"
                     & External_Name & "', value was defined in "
                     & N.Source'Img);
               end if;

               return;
            end if;
         end if;
      end if;

      Name_Len := Value'Length;
      Name_Buffer (1 .. Name_Len) := Value;
      N := new Name_To_Name'
                 (Key    => Key,
                  Source => Source,
                  Value  => Name_Find,
                  Next   => null);

      if not Silent then
         Debug_Output ("Add external (" & External_Name & ") is", N.Value);
      end if;

      Name_To_Name_HTable.Remove (Self.Refs.all, Key);
      Name_To_Name_HTable.Set (Self.Refs.all, N);

   end Add;

   -----------
   -- Check --
   -----------

   function Check
     (Self        : External_References;
      Declaration : String) return Boolean
   is
   begin
      for Equal_Pos in Declaration'Range loop
         if Declaration (Equal_Pos) = '=' then
            exit when Equal_Pos = Declaration'First;
            Add
              (Self          => Self,
               External_Name =>
                 Declaration (Declaration'First .. Equal_Pos - 1),
               Value         =>
                 Declaration (Equal_Pos + 1 .. Declaration'Last),
               Source        => From_Command_Line);
            return True;
         end if;
      end loop;

      return False;
   end Check;

   -----------
   -- Reset --
   -----------

   procedure Reset (Self : External_References) is
   begin
      if Self.Refs /= null then
         Debug_Output ("Reset external references");
         Name_To_Name_HTable.Reset (Self.Refs.all);
      end if;
      if Self.Context /= null then
         Self.Context.Clear;
      end if;
   end Reset;

   --------------
   -- Value_Of --
   --------------

   function Value_Of
     (Self          : External_References;
      External_Name : Name_Id;
      With_Default  : Name_Id := No_Name)
      return          Name_Id
   is
      Value : Name_To_Name_Ptr;
      Val   : Name_Id;
      Name  : String := Get_Name_String (External_Name);

   begin
      Canonical_Case_Env_Var_Name (Name);

      if Self.Refs /= null then
         Value := Name_To_Name_HTable.Get (Self.Refs.all, Get_Name_Id (Name));

         if Value /= null and then Value.Source <= From_Environment then
            Debug_Output ("Value_Of (" & Name & ") is in cache", Value.Value);
            return Value.Value;
         end if;
      end if;

      --  Find if it is an environment, if it is, put value in the hash table

      declare
         Env_Value : String_Access := Getenv (Name);

      begin
         if Env_Value /= null and then Env_Value'Length > 0 then
            Val := Get_Name_Id (Env_Value.all);

            if Current_Verbosity = High then
               Debug_Output ("Value_Of (" & Name & ") is", Val);
            end if;

            if Self.Refs /= null then
               Add
                 (Self, Name, Env_Value.all, From_Environment, Silent => True);
            end if;

            Free (Env_Value);
            return Val;

         else
            if Current_Verbosity = High then
               Debug_Output
                 ("Value_Of (" & Name & ") is default", With_Default);
            end if;

            Free (Env_Value);
            return With_Default;
         end if;
      end;
   end Value_Of;

   ----------
   -- Free --
   ----------

   procedure Free (Self : in out External_References) is
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Name_To_Name_HTable.Instance, Instance_Access);
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Name_To_Name, Name_To_Name_Ptr);
      procedure Unchecked_Free is new Ada.Unchecked_Deallocation
        (Context, Context_Access);
      Ptr  : Name_To_Name_Ptr;
      Size : Natural := 0;
   begin
      if Self.Refs /= null then
         Ptr := Name_To_Name_HTable.Get_First (Self.Refs.all);

         while Ptr /= null loop
            Size := Size + 1;
            Ptr := Name_To_Name_HTable.Get_Next (Self.Refs.all);
         end loop;

         declare
            Ptr_Array : array (1 .. Size) of Name_To_Name_Ptr;
            Idx : Positive := 1;
         begin
            Ptr := Name_To_Name_HTable.Get_First (Self.Refs.all);

            while Ptr /= null loop
               Ptr_Array (Idx) := Ptr;
               Ptr := Name_To_Name_HTable.Get_Next (Self.Refs.all);
               Idx := Idx + 1;
            end loop;

            for J in Ptr_Array'Range loop
               Unchecked_Free (Ptr_Array (J));
            end loop;
         end;

         Reset (Self);
         Unchecked_Free (Self.Refs);
         Unchecked_Free (Self.Context);
      end if;
   end Free;

   --------------
   -- Set_Next --
   --------------

   procedure Set_Next (E : Name_To_Name_Ptr; Next : Name_To_Name_Ptr) is
   begin
      E.Next := Next;
   end Set_Next;

   ----------
   -- Next --
   ----------

   function Next (E : Name_To_Name_Ptr) return Name_To_Name_Ptr is
   begin
      return E.Next;
   end Next;

   -------------
   -- Get_Key --
   -------------

   function Get_Key (E : Name_To_Name_Ptr) return Name_Id is
   begin
      return E.Key;
   end Get_Key;

   -----------------
   -- Get_Context --
   -----------------

   function Get_Context (Self : External_References) return Context is
      Result : Context;
      Cur    : Context_Map.Cursor;

      use Context_Map;
   begin
      if Self.Context /= null then
         Cur := Self.Context.First;
         while Cur /= No_Element loop
            Result.Include
              (Key (Cur),
               Value_Of (Self, Key (Cur), Element (Cur)));
            Next (Cur);
         end loop;
      end if;

      return Result;
   end Get_Context;

   -------------------------
   -- Add_Name_To_Context --
   -------------------------

   procedure Add_Name_To_Context
     (Self          : External_References;
      External_Name : Name_Id;
      Default       : Name_Id)
   is
      Name : String := Get_Name_String (External_Name);
   begin
      if Self.Context /= null then
         Canonical_Case_Env_Var_Name (Name);

         Self.Context.Include (Get_Name_Id (Name), Default);
      end if;
   end Add_Name_To_Context;

   -------------------
   -- Reset_Context --
   -------------------

   procedure Reset_Context (Self : External_References) is
   begin
      if Self.Context /= null then
         Self.Context.Clear;
      end if;
   end Reset_Context;

end GPR.Ext;
