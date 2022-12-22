------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2006-2016, AdaCore                     --
--                                                                          --
-- This is  free  software;  you can redistribute it and/or modify it under --
-- terms of the  GNU  General Public License as published by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for more details.  You should have received  a copy of the  GNU  --
-- General Public License distributed with GNAT; see file  COPYING. If not, --
-- see <http://www.gnu.org/licenses/>.                                      --
--                                                                          --
------------------------------------------------------------------------------

package body Gprexch is

   type String_Ptr is access String;

   Binding_Labels : array (Binding_Section) of String_Ptr;
   --  The list of labels of the different section in a binder exchange file.
   --  Populated in the package body.

   Library_Labels : array (Library_Section) of String_Ptr;
   --  The list of labels of the different section in a library exchange file.
   --  Populated in the package body.

   -------------------
   -- Binding_Label --
   -------------------

   function Binding_Label (Section : Binding_Section) return String is
   begin
      return
        (if Binding_Labels (Section) = null then ""
         else Binding_Labels (Section).all);
   end Binding_Label;

   -------------------------
   -- Get_Binding_Section --
   -------------------------

   function Get_Binding_Section (Label : String) return Binding_Section is
   begin
      for Section in Binding_Section loop
         if Binding_Labels (Section) /= null and then
           Binding_Labels (Section).all = Label
         then
            return Section;
         end if;
      end loop;

      return No_Binding_Section;
   end Get_Binding_Section;

   -------------------------
   -- Get_Library_Section --
   -------------------------

   function Get_Library_Section (Label : String) return Library_Section is
   begin
      for Section in Library_Section loop
         if Library_Labels (Section) /= null and then
           Library_Labels (Section).all = Label
         then
            return Section;
         end if;
      end loop;

      return No_Library_Section;
   end Get_Library_Section;

   -------------------
   -- Library_Label --
   -------------------

   function Library_Label (Section : Library_Section) return String is
   begin
      return
        (if Library_Labels (Section) = null then ""
         else Library_Labels (Section).all);
   end Library_Label;

--  Package elaboration code (build the lists of section labels)

begin
   for J in Binding_Labels'Range loop
      if J /= No_Binding_Section then
         Binding_Labels (J) := new String'('[' & J'Img & ']');

         for K in Binding_Labels (J)'Range loop
            if Binding_Labels (J) (K) = '_' then
               Binding_Labels (J) (K) := ' ';
            end if;
         end loop;
      end if;
   end loop;

   Binding_Labels (No_Binding_Section) := null;

   for J in Library_Labels'Range loop
      if J /= No_Library_Section then
         Library_Labels (J) := new String'('[' & J'Img & ']');

         for K in Library_Labels (J)'Range loop
            if Library_Labels (J) (K) = '_' then
               Library_Labels (J) (K) := ' ';
            end if;
         end loop;
      end if;
   end loop;

   Library_Labels (No_Library_Section) := null;

end Gprexch;
