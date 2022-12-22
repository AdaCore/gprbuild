------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2022, Free Software Foundation, Inc.         --
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

with GPR.Names;  use GPR.Names;
with GPR.Osint;  use GPR.Osint;
with GPR.Snames; use GPR.Snames;
with GPR.Err;    use GPR.Err;

package body GPR.Attr is

   use GNAT;

   Initialized : Boolean := False;
   --  A flag to avoid multiple initialization

   Package_Names     : String_List_Access := new Strings.String_List (1 .. 20);
   Last_Package_Name : Natural := 0;
   --  Package_Names (1 .. Last_Package_Name) contains the list of the known
   --  package names, coming from the Initialization_Data string or from
   --  calls to one of the two procedures Register_New_Package.

   procedure Add_Package_Name (Name : String);
   --  Add a package name in the Package_Name list, extending it, if necessary

   function Name_Id_Of (Name : String) return Name_Id
                        renames Get_Lower_Name_Id;
   --  Returns the Name_Id for Name in lower case

   ----------------------
   -- Add_Package_Name --
   ----------------------

   procedure Add_Package_Name (Name : String) is
   begin
      if Last_Package_Name = Package_Names'Last then
         declare
            New_List : constant Strings.String_List_Access :=
                         new Strings.String_List (1 .. Package_Names'Last * 2);
         begin
            New_List (Package_Names'Range) := Package_Names.all;
            Package_Names := New_List;
         end;
      end if;

      Last_Package_Name := Last_Package_Name + 1;
      Package_Names (Last_Package_Name) := new String'(Name);
   end Add_Package_Name;

   --------------------------
   -- Attribute_Default_Of --
   --------------------------

   function Attribute_Default_Of
     (Attribute : Attribute_Node_Id) return Attribute_Default_Value
   is
   begin
      return
        (if Attribute = Empty_Attribute then Empty_Value
         else Attrs.Table (Attribute.Value).Default);
   end Attribute_Default_Of;

   -----------------------
   -- Attribute_Kind_Of --
   -----------------------

   function Attribute_Kind_Of
     (Attribute : Attribute_Node_Id) return Attribute_Kind
   is
   begin
      return
        (if Attribute = Empty_Attribute then Unknown
         else Attrs.Table (Attribute.Value).Attr_Kind);
   end Attribute_Kind_Of;

   -----------------------
   -- Attribute_Name_Of --
   -----------------------

   function Attribute_Name_Of (Attribute : Attribute_Node_Id) return Name_Id is
   begin
      return
        (if Attribute = Empty_Attribute then No_Name
         else Attrs.Table (Attribute.Value).Name);
   end Attribute_Name_Of;

   --------------------------
   -- Attribute_Node_Id_Of --
   --------------------------

   function Attribute_Node_Id_Of
     (Name        : Name_Id;
      Starting_At : Attribute_Node_Id) return Attribute_Node_Id
   is
      Id : Attr_Node_Id := Starting_At.Value;

   begin
      while Id /= Empty_Attr
        and then Attrs.Table (Id).Name /= Name
      loop
         Id := Attrs.Table (Id).Next;
      end loop;

      return (Value => Id);
   end Attribute_Node_Id_Of;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
      Current_Package : Pkg_Node_Id := Empty_Pkg;

      Pack_Set : Name_Id_Set.Set;
      Attr_Set : Name_Id_Set.Set;
      Position : Name_Id_Set.Cursor;
      Inserted : Boolean;

      function Attribute_Location return String;
      --  Returns a string depending if we are in the project level attributes
      --  or in the attributes of a package.

      procedure Add_Package (Name : Name_Id);

      procedure Add_Attribute
        (Name       : Name_Id;
         Var_Kind   : Variable_Kind;
         Opt_Index  : Boolean                 := False;
         Attr_Kind  : Attribute_Kind;
         Read_Only  : Boolean                 := False;
         Others_Can : Boolean                 := False;
         Default    : Attribute_Default_Value := Empty_Value;
         Conf_Conc  : Boolean);

      -------------------
      -- Add_Attribute --
      -------------------

      procedure Add_Attribute
        (Name       : Name_Id;
         Var_Kind   : Variable_Kind;
         Opt_Index  : Boolean                 := False;
         Attr_Kind  : Attribute_Kind;
         Read_Only  : Boolean                 := False;
         Others_Can : Boolean                 := False;
         Default    : Attribute_Default_Value := Empty_Value;
         Conf_Conc  : Boolean)
      is
         Tab : constant Package_Attributes.Table_Ptr :=
                 Package_Attributes.Table;
      begin
         Attr_Set.Insert (Name, Position, Inserted);

         if not Inserted then
            Error_Msg
              ("duplicate attribute """ & Get_Name_String (Name) & """ in "
               & Attribute_Location, No_Location);
            return;
         end if;

         Attrs.Increment_Last;

         if Current_Package /= Empty_Pkg
           and then Tab (Current_Package).First_Attribute = Empty_Attr
         then
            Tab (Current_Package).First_Attribute := Attrs.Last;

         elsif Attrs.Last > Attrs.First then
            Attrs.Table (Attrs.Last - 1).Next := Attrs.Last;
         end if;

         Attrs.Table (Attrs.Last) :=
           (Name           => Name,
            Var_Kind       => Var_Kind,
            Optional_Index => Opt_Index,
            Attr_Kind      => Attr_Kind,
            Read_Only      => Read_Only,
            Others_Allowed => Others_Can,
            Default        => Default,
            Config_Concat  => Conf_Conc,
            Next           => Empty_Attr);
      end Add_Attribute;

      ------------------------
      -- Attribute_Location --
      ------------------------

      function Attribute_Location return String is
      begin
         return
           (if Current_Package = Empty_Pkg then "project level attributes"
            else "attribute of package """ &
              Get_Name_String
                (Package_Attributes.Table (Current_Package).Name) &
              '"');
      end Attribute_Location;

      -----------------
      -- Add_Package --
      -----------------

      procedure Add_Package (Name : Name_Id) is
         Name_Str : constant String := Get_Name_String (Name);
      begin
         Attr_Set.Clear;
         Pack_Set.Insert (Name, Position, Inserted);

         if not Inserted then
            Error_Msg
              ("duplicate name """  & Name_Str & """ in predefined packages.",
               No_Location);
            return;
         end if;

         Package_Attributes.Increment_Last;
         Current_Package := Package_Attributes.Last;
         Package_Attributes.Table (Current_Package) :=
           (Name             => Name,
            Known            => True,
            First_Attribute  => Empty_Attr);
         Add_Package_Name (Name_Str);
      end Add_Package;

      Opt_Idx_AA : constant Attribute_Kind :=
                     (if Osint.File_Names_Case_Sensitive
                      then Optional_Index_Associative_Array
                      else Optional_Index_Case_Insensitive_Associative_Array);

      Assoc_Array : constant Attribute_Kind :=
                      (if Osint.File_Names_Case_Sensitive
                       then Associative_Array
                       else Case_Insensitive_Associative_Array);

   --  Start of processing for Initialize

   begin
      --  Don't allow Initialize action to be repeated

      if Initialized then
         return;
      end if;

      --  Make sure the two tables are empty

      Attrs.Init;
      Package_Attributes.Init;

      Add_Attribute
        (Name_Name,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Read_Only  => True,
         Default    => Read_Only_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Project_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Read_Only  => True,
         Default    => Read_Only_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Main,
         Var_Kind   => List,
         Opt_Index  => True,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Languages,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Roots,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Externally_Built,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Origin_Project,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Create_Missing_Dirs,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Warning_Message,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Object_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Default    => Dot_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Exec_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Default    => Object_Dir_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Source_Dirs,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Default    => Dot_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Inherit_Source_Path,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Excluded_Source_Dirs,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Ignore_Source_Sub_Dirs,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Only_Dirs_With_Sources,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Source_Files,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Locally_Removed_Files,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Excluded_Source_Files,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Source_List_File,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Excluded_Source_List_File,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Interfaces,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Project_Files,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Project_Path,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_External,
         Var_Kind   => Single,
         Attr_Kind  => Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Name,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Kind,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Version,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Interface,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Standalone,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Encapsulated_Options,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Library_Encapsulated_Supported,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Auto_Init,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Leading_Library_Options,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Library_Options,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Library_Rpath_Options,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Library_Src_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Ali_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_GCC,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Symbol_File,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Symbol_Policy,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Reference_Symbol_File,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Default_Language,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Run_Path_Option,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Run_Path_Origin,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Separate_Run_Path_Options,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Toolchain_Version,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Toolchain_Description,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Toolchain_Name,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Toolchain_Path,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Object_Generated,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Objects_Linked,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Target,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Default    => Target_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Canonical_Target,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Default    => Canonical_Target_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Runtime,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Default    => Runtime_Value,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Runtime_Library_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Runtime_Library_Dirs,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Runtime_Source_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Runtime_Source_Dirs,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Runtime_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Runtime_Library_Version,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Required_Toolchain_Version,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Builder,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Support,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Archive_Builder,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Archive_Builder_Append_Option,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Archive_Indexer,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Archive_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Partial_Linker,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Object_Lister,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Object_Lister_Matcher,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Shared_Library_Prefix,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Shared_Library_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Symbolic_Link_Supported,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Major_Minor_Id_Supported,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Library_Auto_Init_Supported,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Shared_Library_Minimum_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Library_Version_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Library_Install_Name_Option,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);

      Add_Package (Name_Naming);
      Add_Attribute
        (Name_Specification_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Spec_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Implementation_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Body_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Separate_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Casing,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Dot_Replacement,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Specification,
         Var_Kind   => Single,
         Opt_Index  => True,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Spec,
         Var_Kind   => Single,
         Opt_Index  => True,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Implementation,
         Var_Kind   => Single,
         Opt_Index  => True,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Body,
         Var_Kind   => Single,
         Opt_Index  => True,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Specification_Exceptions,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Implementation_Exceptions,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);

      Add_Package (Name_Compiler);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Opt_Idx_AA,
         Others_Can => True,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Local_Configuration_Pragmas,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Local_Config_File,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Driver,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Language_Kind,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Dependency_Kind,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Required_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Leading_Required_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Trailing_Required_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Pic_Option,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Source_File_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Object_File_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Object_File_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Multi_Unit_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Multi_Unit_Object_Separator,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Mapping_File_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Mapping_Spec_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Mapping_Body_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_File_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Config_Body_File_Name,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_Body_File_Name_Index,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_Body_File_Name_Pattern,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_Spec_File_Name,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_Spec_File_Name_Index,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_Spec_File_Name_Pattern,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_File_Unique,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Config_File_Dependency_Support,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Dependency_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Dependency_Driver,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Include_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Include_Switches_Via_Spec,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Include_Path,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Include_Path_File,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Object_Path_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Max_Command_Line_Length,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Response_File_Format,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Response_File_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);

      Add_Package (Name_Builder);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Opt_Idx_AA,
         Others_Can => True,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Global_Compilation_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Executable,
         Var_Kind   => Single,
         Attr_Kind  => Opt_Idx_AA,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Executable_Suffix,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Global_Configuration_Pragmas,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Global_Config_File,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);

      Add_Package (Name_Gnatls);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);

      Add_Package (Name_Binder);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Opt_Idx_AA,
         Others_Can => True,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Driver,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Required_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Prefix,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Objects_Path,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Objects_Path_File,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Bindfile_Option_Substitution,
         Var_Kind   => List,
         Attr_Kind  => Associative_Array,
         Conf_Conc  => False);

      Add_Package (Name_Linker);
      Add_Attribute
        (Name_Required_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Leading_Switches,
         Var_Kind   => List,
         Attr_Kind  => Opt_Idx_AA,
         Others_Can => True,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Opt_Idx_AA,
         Others_Can => True,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Trailing_Switches,
         Var_Kind   => List,
         Attr_Kind  => Opt_Idx_AA,
         Others_Can => True,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Linker_Options,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Map_File_Option,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Driver,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Max_Command_Line_Length,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Response_File_Format,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Response_File_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Export_File_Format,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Export_File_Switch,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Unconditional_Linking,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);

      Add_Package (Name_Clean);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Source_Artifact_Extensions,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Object_Artifact_Extensions,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Artifacts_In_Exec_Dir,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Artifacts_In_Object_Dir,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);

      Add_Package (Name_Cross_Reference);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Others_Can => True,
         Conf_Conc  => True);

      Add_Package (Name_Finder);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Others_Can => True,
         Conf_Conc  => True);

      Add_Package (Name_Pretty_Printer);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Others_Can => True,
         Conf_Conc  => True);

      Add_Package (Name_Gnatstub);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Others_Can => True,
         Conf_Conc  => True);

      Add_Package (Name_Check);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Others_Can => True,
         Conf_Conc  => True);

      Add_Package (Name_Eliminate);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Others_Can => True,
         Conf_Conc  => True);

      Add_Package (Name_Metrics);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Assoc_Array,
         Others_Can => True,
         Conf_Conc  => True);

      Add_Package (Name_Ide);
      Add_Attribute
        (Name_Default_Switches,
         Var_Kind   => List,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Remote_Host,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Program_Host,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Communication_Protocol,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Compiler_Command,
         Var_Kind   => Single,
         Attr_Kind  => Case_Insensitive_Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Debugger_Command,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Gnatlist,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Vcs_Kind,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Vcs_File_Check,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Vcs_Log_Check,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Documentation_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);

      Add_Package (Name_Install);
      Add_Attribute
        (Name_Prefix,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Sources_Subdir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Exec_Subdir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_ALI_Subdir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Lib_Subdir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Project_Subdir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Active,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Install_Project,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Artifacts,
         Var_Kind   => List,
         Attr_Kind  => Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Required_Artifacts,
         Var_Kind   => List,
         Attr_Kind  => Associative_Array,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Mode,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Install_Name,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Side_Debug,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);

      Add_Package (Name_Remote);
      Add_Attribute
        (Name_Root_Dir,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Excluded_Patterns,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Included_Patterns,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Included_Artifact_Patterns,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);

      Add_Package (Name_Stack);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);

      Add_Package (Name_Codepeer);
      Add_Attribute
        (Name_Output_Directory,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Database_Directory,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Message_Patterns,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Additional_Patterns,
         Var_Kind   => Single,
         Attr_Kind  => Single,
         Conf_Conc  => False);
      Add_Attribute
        (Name_Switches,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => True);
      Add_Attribute
        (Name_Excluded_Source_Files,
         Var_Kind   => List,
         Attr_Kind  => Single,
         Conf_Conc  => False);

      Initialized := True;
   end Initialize;

   ----------------------------
   -- Is_Config_Concatenable --
   ----------------------------

   function Is_Config_Concatenable
     (Attribute : Attribute_Node_Id)
      return Boolean
   is
   begin
      return
        (Attribute /= Empty_Attribute)
        and then Attrs.Table (Attribute.Value).Config_Concat;
   end Is_Config_Concatenable;

   ------------------
   -- Is_Read_Only --
   ------------------

   function Is_Read_Only (Attribute : Attribute_Node_Id) return Boolean is
   begin
      return Attrs.Table (Attribute.Value).Read_Only;
   end Is_Read_Only;

   --------------------
   -- Next_Attribute --
   --------------------

   function Next_Attribute
     (After : Attribute_Node_Id) return Attribute_Node_Id
   is
   begin
      return
        (if After = Empty_Attribute then Empty_Attribute
         else (Value => Attrs.Table (After.Value).Next));
   end Next_Attribute;

   -----------------------
   -- Optional_Index_Of --
   -----------------------

   function Optional_Index_Of (Attribute : Attribute_Node_Id) return Boolean is
   begin
      return
        (Attribute /= Empty_Attribute)
        and then Attrs.Table (Attribute.Value).Optional_Index;
   end Optional_Index_Of;

   function Others_Allowed_For
     (Attribute : Attribute_Node_Id) return Boolean
   is
   begin
      return
        (Attribute /= Empty_Attribute)
        and then Attrs.Table (Attribute.Value).Others_Allowed;
   end Others_Allowed_For;

   -----------------------
   -- Package_Name_List --
   -----------------------

   function Package_Name_List return Strings.String_List is
   begin
      return Package_Names (1 .. Last_Package_Name);
   end Package_Name_List;

   ------------------------
   -- Package_Node_Id_Of --
   ------------------------

   function Package_Node_Id_Of (Name : Name_Id) return Package_Node_Id is
   begin
      for Index in Package_Attributes.First .. Package_Attributes.Last loop
         if Package_Attributes.Table (Index).Name = Name then
            return
              (if Package_Attributes.Table (Index).Known then (Value => Index)
               else Unknown_Package);
         end if;
      end loop;

      --  If there is no package with this name, return Empty_Package

      return Empty_Package;
   end Package_Node_Id_Of;

   --------------------------
   -- Attribute_Registered --
   --------------------------

   function Attribute_Registered
     (Name       : String;
      In_Package : Package_Node_Id) return Boolean
   is
      Attr_Name  : Name_Id;
      First_Attr : Attr_Node_Id := Empty_Attr;
      Curr_Attr  : Attr_Node_Id;
   begin
      if Name'Length = 0 then
         Error_Msg ("cannot check an attribute with no name", No_Location);
         return False;
      end if;

      if In_Package = Empty_Package then
         Error_Msg
           ("cannot check an attribute """ & Name
            & """ from an undefined package", No_Location);
         return False;
      end if;

      Attr_Name := Name_Id_Of (Name);

      First_Attr :=
        Package_Attributes.Table (In_Package.Value).First_Attribute;

      --  Check if attribute name is a duplicate

      Curr_Attr := First_Attr;
      while Curr_Attr /= Empty_Attr loop
         if Attrs.Table (Curr_Attr).Name = Attr_Name then
            return True;
         end if;

         Curr_Attr := Attrs.Table (Curr_Attr).Next;
      end loop;

      return False;
   end Attribute_Registered;

   ----------------------------
   -- Register_New_Attribute --
   ----------------------------

   procedure Register_New_Attribute
     (Name                : String;
      In_Package          : Package_Node_Id;
      Attr_Kind           : Defined_Attribute_Kind;
      Var_Kind            : Defined_Variable_Kind;
      Index_Is_File_Name  : Boolean                 := False;
      Opt_Index           : Boolean                 := False;
      Default             : Attribute_Default_Value := Empty_Value;
      Config_Concatenable : Boolean                 := False)
   is
      Attr_Name       : Name_Id;
      First_Attr      : Attr_Node_Id := Empty_Attr;
      Curr_Attr       : Attr_Node_Id;
      Real_Attr_Kind  : Attribute_Kind;

   begin
      if Name'Length = 0 then
         Error_Msg ("cannot register an attribute with no name", No_Location);
         return;
      end if;

      if In_Package = Empty_Package then
         Error_Msg
           ("attempt to add attribute """ & Name
            & """ to an undefined package", No_Location);
         return;
      end if;

      Attr_Name := Name_Id_Of (Name);

      First_Attr :=
        Package_Attributes.Table (In_Package.Value).First_Attribute;

      --  Check if attribute name is a duplicate

      Curr_Attr := First_Attr;
      while Curr_Attr /= Empty_Attr loop
         if Attrs.Table (Curr_Attr).Name = Attr_Name then
            Error_Msg
              ("duplicate attribute name """ & Name & """ in package """
               & Get_Name_String
                   (Package_Attributes.Table (In_Package.Value).Name)
               & """", No_Location);
            return;
         end if;

         Curr_Attr := Attrs.Table (Curr_Attr).Next;
      end loop;

      Real_Attr_Kind := Attr_Kind;

      --  If Index_Is_File_Name, change the attribute kind if necessary

      if Index_Is_File_Name and then not Osint.File_Names_Case_Sensitive then
         case Attr_Kind is
            when Associative_Array =>
               Real_Attr_Kind := Case_Insensitive_Associative_Array;

            when Optional_Index_Associative_Array =>
               Real_Attr_Kind :=
                 Optional_Index_Case_Insensitive_Associative_Array;

            when others =>
               null;
         end case;
      end if;

      --  Add the new attribute

      Attrs.Increment_Last;
      Attrs.Table (Attrs.Last) :=
        (Name           => Attr_Name,
         Var_Kind       => Var_Kind,
         Optional_Index => Opt_Index,
         Attr_Kind      => Real_Attr_Kind,
         Read_Only      => False,
         Others_Allowed => False,
         Default        => Default,
         Config_Concat  => Config_Concatenable,
         Next           => First_Attr);

      Package_Attributes.Table (In_Package.Value).First_Attribute :=
        Attrs.Last;
   end Register_New_Attribute;

   --------------------------
   -- Register_New_Package --
   --------------------------

   procedure Register_New_Package (Name : String; Id : out Package_Node_Id) is
      Pkg_Name : Name_Id;
      Found    : Boolean := False;

   begin
      if Name'Length = 0 then
         Error_Msg ("cannot register a package with no name", No_Location);
         Id := Empty_Package;
         return;
      end if;

      Pkg_Name := Name_Id_Of (Name);

      for Index in Package_Attributes.First .. Package_Attributes.Last loop
         if Package_Attributes.Table (Index).Name = Pkg_Name then
            if Package_Attributes.Table (Index).Known then
               Error_Msg
                 ("cannot register a package with a non unique name """ & Name
                  & """", No_Location);
               Id := Empty_Package;
               return;

            else
               Found := True;
               Id := (Value => Index);
               exit;
            end if;
         end if;
      end loop;

      if not Found then
         Package_Attributes.Increment_Last;
         Id := (Value => Package_Attributes.Last);
      end if;

      Package_Attributes.Table (Id.Value) :=
        (Name             => Pkg_Name,
         Known            => True,
         First_Attribute  => Empty_Attr);

      Add_Package_Name (Get_Name_String (Pkg_Name));
   end Register_New_Package;

   procedure Register_New_Package
     (Name       : String;
      Attributes : Attribute_Data_Array)
   is
      Pkg_Name   : Name_Id;
      Attr_Name  : Name_Id;
      First_Attr : Attr_Node_Id := Empty_Attr;
      Curr_Attr  : Attr_Node_Id;
      Attr_Kind  : Attribute_Kind;

   begin
      if Name'Length = 0 then
         Error_Msg ("cannot register a package with no name", No_Location);
         return;
      end if;

      Pkg_Name := Name_Id_Of (Name);

      for Index in Package_Attributes.First .. Package_Attributes.Last loop
         if Package_Attributes.Table (Index).Name = Pkg_Name then
            Error_Msg
              ("cannot register a package with a non unique name """ & Name
               & '"', No_Location);
            return;
         end if;
      end loop;

      for Index in Attributes'Range loop
         Attr_Name := Name_Id_Of (Attributes (Index).Name);

         Curr_Attr := First_Attr;
         while Curr_Attr /= Empty_Attr loop
            if Attrs.Table (Curr_Attr).Name = Attr_Name then
               Error_Msg
                 ("duplicate attribute name """ & Attributes (Index).Name
                  & """ in new package """ & Name & '"', No_Location);
               return;
            end if;

            Curr_Attr := Attrs.Table (Curr_Attr).Next;
         end loop;

         Attr_Kind := Attributes (Index).Attr_Kind;

         if Attributes (Index).Index_Is_File_Name
           and then not Osint.File_Names_Case_Sensitive
         then
            case Attr_Kind is
               when Associative_Array =>
                  Attr_Kind := Case_Insensitive_Associative_Array;

               when Optional_Index_Associative_Array =>
                  Attr_Kind :=
                    Optional_Index_Case_Insensitive_Associative_Array;

               when others =>
                  null;
            end case;
         end if;

         Attrs.Increment_Last;
         Attrs.Table (Attrs.Last) :=
           (Name           => Attr_Name,
            Var_Kind       => Attributes (Index).Var_Kind,
            Optional_Index => Attributes (Index).Opt_Index,
            Attr_Kind      => Attr_Kind,
            Read_Only      => False,
            Others_Allowed => False,
            Default        => Attributes (Index).Default,
            Config_Concat  => Attributes (Index).Config_Concatenable,
            Next           => First_Attr);
         First_Attr := Attrs.Last;
      end loop;

      Package_Attributes.Increment_Last;
      Package_Attributes.Table (Package_Attributes.Last) :=
        (Name             => Pkg_Name,
         Known            => True,
         First_Attribute  => First_Attr);

      Add_Package_Name (Get_Name_String (Pkg_Name));
   end Register_New_Package;

   ---------------------------
   -- Set_Attribute_Kind_Of --
   ---------------------------

   procedure Set_Attribute_Kind_Of
     (Attribute : Attribute_Node_Id;
      To        : Attribute_Kind)
   is
   begin
      if Attribute /= Empty_Attribute then
         Attrs.Table (Attribute.Value).Attr_Kind := To;
      end if;
   end Set_Attribute_Kind_Of;

   --------------------------
   -- Set_Variable_Kind_Of --
   --------------------------

   procedure Set_Variable_Kind_Of
     (Attribute : Attribute_Node_Id;
      To        : Variable_Kind)
   is
   begin
      if Attribute /= Empty_Attribute then
         Attrs.Table (Attribute.Value).Var_Kind := To;
      end if;
   end Set_Variable_Kind_Of;

   ----------------------
   -- Variable_Kind_Of --
   ----------------------

   function Variable_Kind_Of
     (Attribute : Attribute_Node_Id) return Variable_Kind
   is
   begin
      return
        (if Attribute = Empty_Attribute then Undefined
         else Attrs.Table (Attribute.Value).Var_Kind);
   end Variable_Kind_Of;

   ------------------------
   -- First_Attribute_Of --
   ------------------------

   function First_Attribute_Of
     (Pkg : Package_Node_Id) return Attribute_Node_Id
   is
   begin
      return
        (if Pkg = Empty_Package or else Pkg = Unknown_Package then
           Empty_Attribute
         else (Value => Package_Attributes.Table (Pkg.Value).First_Attribute));
   end First_Attribute_Of;

   ----------------------
   -- Is_Package_Known --
   ----------------------

   function Is_Package_Known (Pkg : Package_Node_Id) return Boolean is
   begin
      return
        not (Pkg = Empty_Package or else Pkg = Unknown_Package)
        and then Package_Attributes.Table (Pkg.Value).Known;
   end Is_Package_Known;

end GPR.Attr;
