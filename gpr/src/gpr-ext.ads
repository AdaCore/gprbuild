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

--  Subprograms to set, get and cache external references, to be used as
--  External functions in project files.

with Ada.Containers.Ordered_Maps;
with GNAT.Dynamic_HTables;

package GPR.Ext is

   -------------------------
   -- External References --
   -------------------------

   --  External references influence the way a project tree is processed (in
   --  particular they provide the values for the typed string variables that
   --  are then used in case constructions).

   --  External references are project-tree specific, so that when multiple
   --  trees are loaded in parallel we can have different scenarios (or even
   --  load the same tree twice and see different views of it).

   type External_References is private;
   No_External_Refs : constant External_References;

   procedure Initialize
     (Self      : out External_References;
      Copy_From : External_References := No_External_Refs);
   --  Initialize Self, and copy all values from Copy_From if needed.
   --  This has no effect if Self was already initialized.

   procedure Free (Self : in out External_References);
   --  Free memory used by Self

   type External_Source is
     (From_Command_Line,
      From_Environment,
      From_External_Attribute);
   --  Indicates where was the value of an external reference defined. They are
   --  prioritized in that order, so that a user can always use the command
   --  line to override a value coming from his environment, or an environment
   --  variable to override a value defined in an aggregate project through the
   --  "for External()..." attribute.

   procedure Add
     (Self          : External_References;
      External_Name : String;
      Value         : String;
      Source        : External_Source := External_Source'First;
      Silent        : Boolean := False);
   --  Add an external reference (or modify an existing one). No overriding is
   --  done if the Source's priority is less than the one used to previously
   --  set the value of the variable. The default for Source is such that
   --  overriding always occurs. When Silent is True, nothing is output even
   --  with non default verbosity.

   function Value_Of
     (Self          : External_References;
      External_Name : Name_Id;
      With_Default  : Name_Id := No_Name)
      return          Name_Id;
   --  Get the value of an external reference, and cache it for future uses

   function Check
     (Self        : External_References;
      Declaration : String) return Boolean;
   --  Check that an external declaration <external>=<value> is correct.
   --  If it is correct, the external reference is Added.

   procedure Reset (Self : External_References);
   --  Clear the internal data structure that stores the external references
   --  and free any allocated memory.

   package Context_Map is new Ada.Containers.Ordered_Maps (Name_Id, Name_Id);
   subtype Context is Context_Map.Map;

   procedure Add_Name_To_Context
     (Self          : External_References;
      External_Name : Name_Id;
      Default       : Name_Id);
   --  Adds given external name to the context

   function Get_Context (Self : External_References) return Context;
   --  Returns all external references currently stored and their values

   procedure Reset_Context (Self : External_References);
   --  Resets Context to empty (but initialized) state.

private
   --  Use a Static_HTable, rather than a Simple_HTable

   --  The issue is that we need to be able to copy the contents of the table
   --  (in Initialize), but this isn't doable for Simple_HTable for which
   --  iterators do not return the key.

   type Name_To_Name;
   type Name_To_Name_Ptr is access all Name_To_Name;
   type Name_To_Name is record
      Key    : Name_Id;
      Value  : Name_Id;
      Source : External_Source;
      Next   : Name_To_Name_Ptr;
   end record;

   procedure Set_Next (E : Name_To_Name_Ptr; Next : Name_To_Name_Ptr);
   function  Next     (E : Name_To_Name_Ptr) return Name_To_Name_Ptr;
   function  Get_Key  (E : Name_To_Name_Ptr) return Name_Id;

   package Name_To_Name_HTable is new GNAT.Dynamic_HTables.Static_HTable
     (Header_Num => Header_Num,
      Element    => Name_To_Name,
      Elmt_Ptr   => Name_To_Name_Ptr,
      Null_Ptr   => null,
      Set_Next   => Set_Next,
      Next       => Next,
      Key        => Name_Id,
      Get_Key    => Get_Key,
      Hash       => Hash,
      Equal      => "=");
   --  General type for htables associating name_id to name_id. This is in
   --  particular used to store the values of external references.

   type Instance_Access is access all Name_To_Name_HTable.Instance;

   type Context_Access is access all Context;

   type External_References is record
      Refs : Instance_Access;
      --  External references are stored in this hash table (and manipulated
      --  through subprogrames in prj-ext.ads). External references are
      --  project-tree specific so that one can load the same tree twice but
      --  have two views of it, for instance.

      Context : Context_Access;
      --  Names of all external references used in project tree
   end record;

   No_External_Refs : constant External_References :=
     (Refs => null, Context => null);

end GPR.Ext;
