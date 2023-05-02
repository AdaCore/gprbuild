------------------------------------------------------------------------------
--                                                                          --
--                             GPR TECHNOLOGY                               --
--                                                                          --
--                     Copyright (C) 2012-2023, AdaCore                     --
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

with Ada.Characters.Handling;                use Ada.Characters.Handling;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Indefinite_Vectors;      use Ada;
with Ada.Containers.Vectors;
with Ada.Directories;                        use Ada.Directories;
with Ada.Strings.Equal_Case_Insensitive;
with Ada.Strings.Fixed;                      use Ada.Strings;
with Ada.Strings.Less_Case_Insensitive;
with Ada.Strings.Unbounded;                  use Ada.Strings.Unbounded;
with Ada.Text_IO;                            use Ada.Text_IO;

with GNAT.MD5;    use GNAT.MD5;
with GNAT.OS_Lib;
with GNAT.String_Split;

with GPR.Names;      use GPR.Names;
with GPR.Opt;
with GPR.Osint;      use GPR.Osint;
with GPR.PP;         use GPR.PP;
with GPR.Snames;     use GPR.Snames;
with GPR.Tree;
with GPR.Util;       use GPR.Util;
with GPR.Version;    use GPR.Version;
with Gpr_Build_Util; use Gpr_Build_Util;

package body Gprinstall.Install is

   use GNAT;

   package String_Vector is
     new Containers.Indefinite_Vectors (Positive, String);

   package Seen_Set renames GPR.String_Sets;

   Content : String_Vector.Vector;
   --  The content of the project, this is used when creating the project
   --  and is needed to ease the project section merging when installing
   --  multiple builds.

   Initial_Buffer_Size : constant := 100;
   --  Arbitrary value for the initial size of the buffer below

   Buffer : GNAT.OS_Lib.String_Access := new String (1 .. Initial_Buffer_Size);
   Buffer_Last : Natural := 0;

   Agg_Manifest : Text_IO.File_Type;
   --  Manifest file for main aggregate project

   Line_Manifest     : Text_IO.Count := 0;
   Line_Agg_Manifest : Text_IO.Count := 0;
   --  Keep lines when opening the manifest files. This is used by the rollback
   --  routine when an error occurs while copying the files.

   Objcopy_Exec : constant String :=
                    (if Target_Name = null
                     then "objcopy"
                     else Target_Name.all & "-objcopy");
   --  Name of objcopy executable, possible a cross one

   Strip_Exec   : constant String :=
                    (if Target_Name = null
                     then "strip"
                     else Target_Name.all & "-strip");
   --  Name of strip executable, possible a cross one

   Objcopy      : constant OS_Lib.String_Access :=
                    OS_Lib.Locate_Exec_On_Path (Objcopy_Exec);
   Strip        : constant OS_Lib.String_Access :=
                    OS_Lib.Locate_Exec_On_Path (Strip_Exec);

   procedure Double_Buffer;
   --  Double the size of the Buffer

   procedure Write_Char (C : Character);
   --  Append character C to the Buffer. Double the buffer if needed

   procedure Write_Eol;
   --  Append the content of the Buffer as a line to Content and empty the
   --  Buffer.

   procedure Write_Str (S : String);
   --  Append S to the buffer. Double the buffer if needed

   Installed : Name_Id_Set.Set;
   --  Record already installed project

   Prep_Suffix : constant String := ".prep";

   type Type_Node;
   type Type_Node_Ref is access Type_Node;

   type Type_Node is record
      String_Type : Project_Node_Id := Empty_Project_Node;
      Next        : Type_Node_Ref;
   end record;

   -------------
   -- Process --
   -------------

   procedure Process
     (Tree      : GPR.Project_Tree_Ref;
      Node_Tree : GPR.Project_Node_Tree_Ref;
      Project   : GPR.Project_Id)
   is

      Windows_Target : constant Boolean :=
                         Get_Name_String
                           (Project.Config.Shared_Lib_Suffix) = ".dll";

      Pcks : constant Package_Table.Table_Ptr := Tree.Shared.Packages.Table;
      Strs : constant String_Element_Table.Table_Ptr :=
               Tree.Shared.String_Elements.Table;
      Vels : constant Variable_Element_Table.Table_Ptr :=
               Tree.Shared.Variable_Elements.Table;

      --  Local values for the given project, these are initially set with the
      --  default values. It is updated using the Install package found in the
      --  project if any.

      Active          : Boolean := True;
      --  Whether installation is active or not (Install package's attribute)

      Side_Debug      : Boolean := Gprinstall.Side_Debug;
      --  Whether to extract debug symbols from executables and shared
      --  libraries. Default to global value.

      Prefix_Dir      : Param := Dup (Global_Prefix_Dir);
      Exec_Subdir     : Param := Dup (Global_Exec_Subdir);
      Lib_Subdir      : Param := Dup (Global_Lib_Subdir);
      ALI_Subdir      : Param := Dup (Global_ALI_Subdir);
      Link_Lib_Subdir : Param := Dup (Global_Link_Lib_Subdir);
      Sources_Subdir  : Param := Dup (Global_Sources_Subdir);
      Project_Subdir  : Param := Dup (Global_Project_Subdir);
      Install_Mode    : Param := Dup (Global_Install_Mode);
      Install_Name    : Param := Dup (Global_Install_Name);
      Install_Project : Boolean := Global_Install_Project;

      type Items is (Source, Object, Dependency, Library, Executable);

      Copy : array (Items) of Boolean := (others => False);
      --  What should be copied from a project, this depends on the actual
      --  project kind and the mode (usage, dev) set for the install.

      Man : Text_IO.File_Type;
      --  File where manifest for this project is kept

      --  Keeping track of artifacts to install

      type Artifacts_Data is record
         Destination, Filename : Name_Id;
         Required              : Boolean;
      end record;

      package Artifacts_Set is
        new Containers.Vectors (Positive, Artifacts_Data);

      Artifacts : Artifacts_Set.Vector;

      Excluded_Naming : Seen_Set.Set;
      --  This set contains names of Ada unit to exclude from the generated
      --  package Naming. This is needed to avoid renaming for bodies which
      --  are not installed when the minimum installation (-m) is used. In
      --  this case there is two points to do:
      --
      --  1. the installed .ali must use the spec naming
      --
      --  2. the naming convention for the body must be excluded from the
      --     generated project.

      procedure Copy_File
        (From, To, File : String;
         From_Ver       : String  := "";
         Sym_Link       : Boolean := False;
         Executable     : Boolean := False;
         Extract_Debug  : Boolean := False);
      --  Copy file From into To, if Sym_Link is set a symbolic link is
      --  created. If Executable is set, the destination file exec attribute
      --  is set. When Extract_Debug is set to True the debug information
      --  for the executable is written in a side file.

      function Dir_Name (Suffix : Boolean := True) return String;
      --  Returns the name of directory where project files are to be
      --  installed. This name is the name of the project. If Suffix is
      --  True then the build name is also returned.

      function Cat
        (Dir : Path_Name_Type; File : File_Name_Type) return String;
      pragma Inline (Cat);
      --  Returns the string which is the catenation of Dir and File

      function Sources_Dir (Build_Name : Boolean := True) return String;
      --  Returns the full pathname to the sources destination directory

      function Exec_Dir return String;
      --  Returns the full pathname to the executable destination directory

      function Lib_Dir (Build_Name : Boolean := True) return String;
      --  Returns the full pathname to the library destination directory

      function ALI_Dir (Build_Name : Boolean := True) return String;
      --  Returns the full pathname to the library destination directory

      function Link_Lib_Dir return String;
      --  Returns the full pathname to the lib symlib directory

      function Project_Dir return String;
      --  Returns the full pathname to the project destination directory

      procedure Check_Install_Package;
      --  Check Project's install package and overwrite the default values of
      --  the corresponding variables above.

      procedure Copy_Files;
      --  Do the file copies for the project's sources, objects, library,
      --  executables.

      procedure Create_Project (Project : Project_Id);
      --  Create install project for the given project

      procedure Add_To_Manifest
        (Pathname       : String;
         Aggregate_Only : Boolean := False);
      --  Add filename to manifest

      function Get_Library_Filename return File_Name_Type;
      --  Returns the actual file name for the library

      function Has_Sources (Project : Project_Id) return Boolean;
      pragma Inline (Has_Sources);
      --  Returns True if the project contains sources

      function Bring_Sources (Project : Project_Id) return Boolean;
      --  Returns True if Project gives visibility to some sources directly or
      --  indirectly via the with clauses.

      function Main_Binary (Source : Name_Id) return String;
      --  Give the source name found in the Main attribute, returns the actual
      --  binary as built by gprbuild. This routine looks into the Builder
      --  switches for a the Executable attribute.

      function Is_Install_Active (Project : Project_Id) return Boolean;
      --  Returns True if the Project is active, that is there is no attribute
      --  Active set to False in the Install package.

      procedure Open_Check_Manifest
        (File : out Text_IO.File_Type; Current_Line : out Text_IO.Count);
      --  Check that manifest file can be used

      procedure Rollback_Manifests;
      --  Rollback manifest files (for current project or/and aggregate one)

      function For_Dev return Boolean is (Install_Mode.V.all = "dev");

      -------------
      -- ALI_Dir --
      -------------

      function ALI_Dir (Build_Name : Boolean := True) return String is
         Install_Name_Dir : constant String :=
                              (if Install_Name.Default
                               then ""
                               else Install_Name.V.all & "/");
      begin
         if Is_Absolute_Path (ALI_Subdir.V.all) then
            return ALI_Subdir.V.all & Install_Name_Dir;

         elsif not ALI_Subdir.Default or else not Build_Name then
            return Prefix_Dir.V.all & ALI_Subdir.V.all & Install_Name_Dir;

         else
            return Ensure_Directory
              (Prefix_Dir.V.all & ALI_Subdir.V.all & Install_Name_Dir
               & Dir_Name);
         end if;
      end ALI_Dir;

      ---------------------
      -- Add_To_Manifest --
      ---------------------

      procedure Add_To_Manifest
        (Pathname       : String;
         Aggregate_Only : Boolean := False) is
      begin
         if not Aggregate_Only and then not Is_Open (Man) then
            Open_Check_Manifest (Man, Line_Manifest);
         end if;

         --  Append entry into manifest

         declare
            function N (Str : String) return String
              is (Normalize_Pathname (Str, Case_Sensitive => False));

            MD5  : constant String := File_MD5 (Pathname);
            Path : constant String := Containing_Directory (Pathname);
            File : constant String := Simple_Name (Pathname);
         begin
            if not Aggregate_Only and then Is_Open (Man) then
               Put_Line
                 (Man,
                  MD5 & ' '
                  & Util.Relative_Path
                    (N (Path), Containing_Directory (N (Name (Man))))
                  & File);
            end if;

            if Is_Open (Agg_Manifest) then
               Put_Line
                 (Agg_Manifest,
                  MD5 & ' '
                  & Util.Relative_Path
                    (N (Path), Containing_Directory (N (Name (Agg_Manifest))))
                  & File);
            end if;
         end;
      end Add_To_Manifest;

      -------------------
      -- Bring_Sources --
      -------------------

      function Bring_Sources (Project : Project_Id) return Boolean is
      begin
         if Has_Sources (Project) then
            return True;

         else
            declare
               List : Project_List := Project.All_Imported_Projects;
            begin
               while List /= null loop
                  if Has_Sources (List.Project) then
                     return True;
                  end if;
                  List := List.Next;
               end loop;
            end;
         end if;

         return False;
      end Bring_Sources;

      ---------------------------
      -- Check_Install_Package --
      ---------------------------

      procedure Check_Install_Package is
         Pck : Package_Id := Project.Decl.Packages;

         procedure Replace
           (P         : in out Param;
            Val       : Name_Id;
            Is_Dir    : Boolean := True;
            Normalize : Boolean := False);
         pragma Inline (Replace);
         --  Set Var with Value, free previous pointer

         -------------
         -- Replace --
         -------------

         procedure Replace
           (P         : in out Param;
            Val       : Name_Id;
            Is_Dir    : Boolean := True;
            Normalize : Boolean := False)
         is
            V : constant String := Get_Name_String (Val);
         begin
            if V /= "" then
               Free (P.V);
               P := (new String'
                       ((if Is_Dir
                        then (if Normalize
                              then Ensure_Directory (Normalize_Pathname (V))
                              else Ensure_Directory (V))
                         else V)),
                     Default => False);
            end if;
         end Replace;

      begin
         Look_Install_Package : while Pck /= No_Package loop
            if Pcks (Pck).Decl /= No_Declarations
              and then Pcks (Pck).Name = Name_Install
            then
               --  Found Install package, check attributes

               declare
                  Id : Variable_Id := Pcks (Pck).Decl.Attributes;
               begin
                  while Id /= No_Variable loop
                     declare
                        V : constant Variable := Vels (Id);
                     begin
                        if V.Name = Name_Prefix then
                           --  If Install.Prefix is a relative path, it is made
                           --  relative to the global prefix.

                           declare
                              Value   : constant String :=
                                          Get_Name_String (V.Value.Value);
                              Res     : Name_Id;
                              Changed : Boolean := False;
                           begin
                              if Is_Absolute_Path (Value) then
                                 if Global_Prefix_Dir.Default then
                                    Res := V.Value.Value;
                                    Changed := True;
                                 end if;

                              else
                                 Set_Name_Buffer (Global_Prefix_Dir.V.all);
                                 Add_Str_To_Name_Buffer (Value);
                                 Res := Name_Find;
                                 Changed := True;
                              end if;

                              if Changed then
                                 Replace (Prefix_Dir, Res, Normalize => True);
                              end if;
                           end;

                        elsif  V.Name = Name_Exec_Subdir
                          and then Global_Exec_Subdir.Default
                        then
                           Replace (Exec_Subdir, V.Value.Value);

                        elsif V.Name = Name_Lib_Subdir
                          and then Global_Lib_Subdir.Default
                        then
                           Replace (Lib_Subdir, V.Value.Value);

                        elsif V.Name = Name_ALI_Subdir
                          and then Global_ALI_Subdir.Default
                        then
                           Replace (ALI_Subdir, V.Value.Value);

                        elsif V.Name = Name_Link_Lib_Subdir
                          and then Global_Link_Lib_Subdir.Default
                        then
                           Replace (Link_Lib_Subdir, V.Value.Value);

                        elsif V.Name = Name_Sources_Subdir
                          and then Global_Sources_Subdir.Default
                        then
                           Replace (Sources_Subdir, V.Value.Value);

                        elsif V.Name = Name_Project_Subdir
                          and then Global_Project_Subdir.Default
                        then
                           Replace (Project_Subdir, V.Value.Value);

                        elsif V.Name = Name_Mode
                          and then Global_Install_Mode.Default
                        then
                           Replace (Install_Mode, V.Value.Value);

                        elsif V.Name = Name_Install_Name
                          and then Global_Install_Name.Default
                        then
                           Replace
                             (Install_Name, V.Value.Value, Is_Dir => False);

                        elsif V.Name = Name_Active then
                           declare
                              Val : constant String :=
                                      To_Lower
                                        (Get_Name_String (V.Value.Value));
                           begin
                              Active := Val /= "false";
                           end;

                        elsif V.Name = Name_Side_Debug then
                           declare
                              Val : constant String :=
                                      To_Lower
                                        (Get_Name_String (V.Value.Value));
                           begin
                              Side_Debug := Val = "true";
                           end;

                        elsif V.Name = Name_Install_Project then
                           declare
                              Val : constant String :=
                                      To_Lower
                                        (Get_Name_String (V.Value.Value));
                           begin
                              Install_Project := Val /= "false";
                           end;

                        end if;
                     end;
                     Id := Vels (Id).Next;
                  end loop;
               end;

               --  Now check arrays

               declare
                  Id : Array_Id := Pcks (Pck).Decl.Arrays;
               begin
                  while Id /= No_Array loop
                     declare
                        V : constant Array_Data :=
                              Tree.Shared.Arrays.Table (Id);
                     begin
                        if V.Name in
                          Name_Artifacts | Name_Required_Artifacts
                        then
                           declare
                              Eid : Array_Element_Id := V.Value;
                           begin
                              while Eid /= No_Array_Element loop
                                 declare
                                    E : constant Array_Element :=
                                          Tree.Shared.Array_Elements.Table
                                            (Eid);
                                    S : String_List_Id := E.Value.Values;
                                 begin
                                    while S /= Nil_String loop
                                       Artifacts.Append
                                         (Artifacts_Data'
                                            (E.Index, Strs (S).Value,
                                             Required =>
                                               (if V.Name = Name_Artifacts
                                                then False else True)));
                                       S := Strs (S).Next;
                                    end loop;
                                 end;

                                 Eid := Tree.Shared.Array_Elements.
                                   Table (Eid).Next;
                              end loop;
                           end;
                        end if;
                     end;
                     Id := Tree.Shared.Arrays.Table (Id).Next;
                  end loop;
               end;

               exit Look_Install_Package;
            end if;

            Pck := Pcks (Pck).Next;
         end loop Look_Install_Package;

         --  Now check if Lib_Subdir is set and not ALI_Subdir as in this case
         --  we want ALI_Subdir to be equal to Lib_Subdir.

         if not Lib_Subdir.Default
           and then ALI_Subdir.Default
         then
            ALI_Subdir := Dup (Lib_Subdir);
         end if;
      end Check_Install_Package;

      --------------
      -- Dir_Name --
      --------------

      function Dir_Name (Suffix : Boolean := True) return String is

         function Get_Suffix return String;
         --  Returns a suffix if needed

         ----------------
         -- Get_Suffix --
         ----------------

         function Get_Suffix return String is
         begin
            --  .default is always omitted from the directory name

            return
              (if Suffix and then Build_Name.all /= "default" then
                 '.' & Build_Name.all
               else "");
         end Get_Suffix;

      begin
         return Get_Name_String (Project.Name) & Get_Suffix;
      end Dir_Name;

      ---------------------------
      -- Get_Library_Filenaame --
      ---------------------------

      function Get_Library_Filename return File_Name_Type is
      begin
         --  Library prefix

         if not Is_Static (Project)
           and then Project.Config.Shared_Lib_Prefix /= No_File
         then
            Get_Name_String (Project.Config.Shared_Lib_Prefix);
         else
            Set_Name_Buffer ("lib");
         end if;

         --  Library name

         Get_Name_String_And_Append (Project.Library_Name);

         --  Library suffix

         if Is_Static (Project)
           and then Project.Config.Archive_Suffix /= No_File
         then
            Get_Name_String_And_Append (Project.Config.Archive_Suffix);

         elsif not Is_Static (Project)
           and then Project.Config.Shared_Lib_Suffix /= No_File
         then
            Get_Name_String_And_Append (Project.Config.Shared_Lib_Suffix);

         else
            Add_Str_To_Name_Buffer (".so");
         end if;

         return Name_Find;
      end Get_Library_Filename;

      -----------------------
      -- Is_Install_Active --
      -----------------------

      function Is_Install_Active (Project : Project_Id) return Boolean is
         Pck  : Package_Id := Project.Decl.Packages;
      begin
         Look_Install_Package : while Pck /= No_Package loop
            if Pcks (Pck).Decl /= No_Declarations
              and then Pcks (Pck).Name = Name_Install
            then
               --  Found Install package, check attributes

               declare
                  Id : Variable_Id := Pcks (Pck).Decl.Attributes;
               begin
                  while Id /= No_Variable loop
                     declare
                        V : constant Variable := Vels (Id);
                     begin
                        if V.Name = Name_Active then
                           declare
                              Val : constant String :=
                                      To_Lower
                                        (Get_Name_String (V.Value.Value));
                           begin
                              return Val /= "false";
                           end;
                        end if;
                     end;
                     Id := Vels (Id).Next;
                  end loop;
               end;

               exit Look_Install_Package;
            end if;

            Pck := Pcks (Pck).Next;
         end loop Look_Install_Package;

         --  If not defined, the default is active

         return True;
      end Is_Install_Active;

      -----------------
      -- Main_Binary --
      -----------------

      function Main_Binary (Source : Name_Id) return String is

         function Get_Exec_Suffix return String;
         --  Return the target executable suffix

         ---------------------
         -- Get_Exec_Suffix --
         ---------------------

         function Get_Exec_Suffix return String is
         begin
            return
              (if Project.Config.Executable_Suffix = No_Name then ""
               else Get_Name_String (Project.Config.Executable_Suffix));
         end Get_Exec_Suffix;

         Builder_Package  : constant Package_Id :=
                              Value_Of
                                (Name_Builder, Project.Decl.Packages,
                                 Project_Tree.Shared);
         Value            : Variable_Value;

      begin
         if Builder_Package /= No_Package then
            Value := Value_Of
              (Name                    => Source,
               Attribute_Or_Array_Name => Name_Executable,
               In_Package              => Builder_Package,
               Shared                  => Project_Tree.Shared);

            if Value = Nil_Variable_Value then

               --  If not found and name has an extension

               declare
                  Name : constant String := Get_Name_String (Source);
                  S    : Name_Id;
               begin
                  if Name /= Base_Name (Name) then
                     Set_Name_Buffer (Base_Name (Name));
                     S := Name_Find;

                     Value := Value_Of
                       (Name                    => S,
                        Attribute_Or_Array_Name => Name_Executable,
                        In_Package              => Builder_Package,
                        Shared                  => Project_Tree.Shared);
                  end if;
               end;
            end if;
         end if;

         if Value = Nil_Variable_Value then
            declare
               Simple_Name : constant String :=
                               Get_Name_String (Source);
               Last        : Positive := Simple_Name'First;
            begin
               --  Cut executable name at the first . (extension). Note that
               --  this is not necessary the first base-name as we may have
               --  multiple dots in the source when using non standard naming.
               --  For example, having "main.2.ada" whe want to get on "main".

               while Last < Simple_Name'Last
                 and then Simple_Name (Last + 1) /= '.'
               loop
                  Last := Last + 1;
               end loop;

               return Simple_Name (Simple_Name'First .. Last)
                 & Get_Exec_Suffix;
            end;

         else
            return Get_Name_String (Value.Value) & Get_Exec_Suffix;
         end if;
      end Main_Binary;

      -----------------
      -- Has_Sources --
      -----------------

      function Has_Sources (Project : Project_Id) return Boolean is
      begin
         return Project.Source_Dirs /= Nil_String
           or else Project.Qualifier = Aggregate_Library;
      end Has_Sources;

      --------------
      -- Exec_Dir --
      --------------

      function Exec_Dir return String is
      begin
         return
           (if Is_Absolute_Path (Exec_Subdir.V.all) then Exec_Subdir.V.all
            else Prefix_Dir.V.all & Exec_Subdir.V.all);
      end Exec_Dir;

      -------------
      -- Lib_Dir --
      -------------

      function Lib_Dir (Build_Name : Boolean := True) return String is
         Install_Name_Dir : constant String :=
                              (if Install_Name.Default
                               then ""
                               else Install_Name.V.all & "/");
      begin
         if Is_Absolute_Path (Lib_Subdir.V.all) then
            return Lib_Subdir.V.all & Install_Name_Dir;

         elsif not Lib_Subdir.Default or else not Build_Name then
            return Prefix_Dir.V.all & Lib_Subdir.V.all & Install_Name_Dir;

         else
            return Ensure_Directory
              (Prefix_Dir.V.all & Lib_Subdir.V.all & Install_Name_Dir
               & Dir_Name);
         end if;
      end Lib_Dir;

      ------------------
      -- Link_Lib_Dir --
      ------------------

      function Link_Lib_Dir return String is
      begin
         return
           (if Is_Absolute_Path (Link_Lib_Subdir.V.all) then
              Link_Lib_Subdir.V.all
            else Prefix_Dir.V.all & Link_Lib_Subdir.V.all);
      end Link_Lib_Dir;

      -----------------
      -- Sources_Dir --
      -----------------

      function Sources_Dir (Build_Name : Boolean := True) return String is
         Install_Name_Dir : constant String :=
                              (if Install_Name.Default
                               then ""
                               else Install_Name.V.all & "/");
      begin
         if Is_Absolute_Path (Sources_Subdir.V.all) then
            return Sources_Subdir.V.all & Install_Name_Dir;

         elsif not Sources_Subdir.Default or else not Build_Name then
            return Prefix_Dir.V.all & Sources_Subdir.V.all & Install_Name_Dir;

         else
            return Ensure_Directory
              (Prefix_Dir.V.all & Sources_Subdir.V.all & Install_Name_Dir
               & Dir_Name);
         end if;
      end Sources_Dir;

      -----------------
      -- Project_Dir --
      -----------------

      function Project_Dir return String is
      begin
         return
           (if Is_Absolute_Path (Project_Subdir.V.all) then
              Project_Subdir.V.all
            else Prefix_Dir.V.all & Project_Subdir.V.all);
      end Project_Dir;

      ---------
      -- Cat --
      ---------

      function Cat
        (Dir : Path_Name_Type; File : File_Name_Type) return String is
      begin
         return Get_Name_String (Dir) & Get_Name_String (File);
      end Cat;

      ---------------
      -- Copy_File --
      ---------------

      procedure Copy_File
        (From, To, File : String;
         From_Ver       : String  := "";
         Sym_Link       : Boolean := False;
         Executable     : Boolean := False;
         Extract_Debug  : Boolean := False)
      is
         Dest_Filename : aliased String := To & File;
      begin
         if Sym_Link and then On_Windows then
            Put ("Internal error: cannot use symbolic links on Windows");
            New_Line;
            Finish_Program (Project_Tree, E_Fatal);
         end if;

         if not Sym_Link
           and then Exists (Dest_Filename)
           and then not Force_Installations
           and then File_MD5 (From) /= File_MD5 (Dest_Filename)
         then
            Put ("file ");
            Put (File);
            Put (" exists, use -f to overwrite");
            New_Line;
            Finish_Program (Project_Tree, E_Fatal);
         end if;

         if Dry_Run or else Opt.Verbose_Mode then
            Put ((if Sym_Link then "ln -s " else "cp "));

            Put (From);
            Put (" ");
            Put (Dest_Filename);
            New_Line;
         end if;

         if not Dry_Run then
            --  If file exists and is read-only, first remove it

            if not Sym_Link and then Exists (Dest_Filename) then
               if not Is_Writable_File (Dest_Filename) then
                  Set_Writable (Dest_Filename);
               end if;

               declare
                  Success : Boolean;
               begin
                  Delete_File (Dest_Filename, Success);

                  if not Success then
                     Put ("cannot overwrite ");
                     Put (Dest_Filename);
                     Put (" check permissions");
                     New_Line;
                     Finish_Program (Project_Tree, E_Fatal);
                  end if;
               end;
            end if;

            if not Sym_Link and then not Exists (From) then
               Put ("file ");
               Put (From);
               Put (" does not exist, build may not be complete");
               New_Line;
               Finish_Program (Project_Tree, E_Fatal);
            end if;

            if (not Sym_Link and then not Exists (To))
              or else (Sym_Link and then not Exists (From))
            then
               if Create_Dest_Dir then
                  begin
                     Create_Path
                       ((if Sym_Link then Containing_Directory (From)
                         else To));
                  exception
                     when Text_IO.Use_Error =>
                        --  Cannot create path, permission issue
                        Put ("cannot create destination directory ");
                        Put (if Sym_Link
                             then Containing_Directory (From)
                             else To);
                        Put (" check permissions");
                        New_Line;
                        Finish_Program (Project_Tree, E_Fatal);
                  end;

               else
                  Put_Line
                    (Standard_Error,
                     "target directory "
                     & To & " does not exist, use -p to create");
                  Finish_Program (Project_Tree, E_Fatal);
               end if;
            end if;

            --  Do copy

            if Sym_Link then
               Create_Sym_Link (From, To & File);

               --  Add file to manifest

               if Install_Manifest then
                  Add_To_Manifest (From);
               end if;

               if From_Ver /= "" then
                  Create_Sym_Link (From_Ver, To & File);

                  if Install_Manifest then
                     Add_To_Manifest (From_Ver);
                  end if;
               end if;

            else
               begin
                  Ada.Directories.Copy_File
                    (Source_Name => From,
                     Target_Name => Dest_Filename,
                     Form        => "preserve=timestamps");
               exception
                  when Text_IO.Use_Error =>
                     Put_Line
                       ("cannot overwrite file " & Dest_Filename
                        & " check permissions.");
                     Finish_Program (Project_Tree, E_Fatal);
               end;

               if Executable then
                  Set_Executable
                    (Dest_Filename, Mode => S_Owner + S_Group + S_Others);

                  --  Furthermore, if we have an executable and we ask for
                  --  separate debug symbols we do it now.
                  --  The commands to run are:
                  --    $ objcopy --only-keep-debug <exec> <exec>.debug
                  --    $ strip <exec>
                  --    $ objcopy --add-gnu-debuglink=<exec>.debug <exec>

                  if Extract_Debug then
                     if Objcopy = null then
                        Put_Line
                          (Objcopy_Exec & " not found, "
                           & "cannot create side debug file for "
                           & Dest_Filename);

                     elsif Strip = null then
                        Put_Line
                          (Strip_Exec & " not found, "
                           & "cannot create side debug file for "
                           & Dest_Filename);

                     else
                        declare
                           Keep_Debug : aliased String :=
                                          "--only-keep-debug";
                           Dest_Debug : aliased String :=
                                          Dest_Filename & ".debug";
                           Link_Debug : aliased String :=
                                          "--add-gnu-debuglink=" & Dest_Debug;
                           Success    : Boolean;
                           Args       : Argument_List (1 .. 3);
                        begin
                           --  1. copy the debug symbols:

                           Args (1) := Keep_Debug'Unchecked_Access;
                           Args (2) := Dest_Filename'Unchecked_Access;
                           Args (3) := Dest_Debug'Unchecked_Access;

                           OS_Lib.Spawn (Objcopy.all, Args, Success);

                           if Success then
                              --  Record the debug file in the manifest
                              if Install_Manifest then
                                 Add_To_Manifest (Dest_Debug);
                              end if;

                              --  2. strip original executable

                              Args (1) := Dest_Filename'Unchecked_Access;

                              OS_Lib.Spawn (Strip.all, Args (1 .. 1), Success);

                              if Success then
                                 --  2. link debug symbols file with original
                                 --  file.

                                 Args (1) := Link_Debug'Unchecked_Access;
                                 Args (2) := Dest_Filename'Unchecked_Access;

                                 OS_Lib.Spawn
                                   (Objcopy.all, Args (1 .. 2), Success);

                                 if not Success then
                                    Put_Line
                                      (Objcopy_Exec & " error, "
                                       & "cannot link debug symbol file with"
                                       & " original executable "
                                       & Dest_Filename);
                                 end if;

                              else
                                 Put_Line
                                   (Strip_Exec & " error, "
                                    & "cannot remove debug symbols from "
                                    & Dest_Filename);
                              end if;

                           else
                              Put_Line
                                (Objcopy_Exec & " error, "
                                 & "cannot create side debug file for "
                                 & Dest_Filename);
                           end if;
                        end;
                     end if;
                  end if;
               end if;

               --  Add file to manifest

               if Install_Manifest then
                  Add_To_Manifest (Dest_Filename);
               end if;
            end if;
         end if;
      end Copy_File;

      ----------------
      -- Copy_Files --
      ----------------

      procedure Copy_Files is

         procedure Copy_Project_Sources (Project : Project_Id);
         --  Copy sources from the given project

         procedure Copy_Source (Sid : Source_Id);

         procedure Copy_Artifacts
           (Pathname, Destination : String;
            Required              : Boolean);
         --  Copy items from the artifacts attribute

         Source_Copied : Name_Id_Set.Set;

         --------------------------
         -- Copy_Project_Sources --
         --------------------------

         procedure Copy_Project_Sources (Project : Project_Id) is
            function Is_Ada (Sid : Source_Id) return Boolean with Inline;
            --  Returns True if Sid is an Ada source

            function Is_Part_Of_Aggregate_Lib
              (Aggregate_Lib_Project :  Project_Id;
               Sid                   : Source_Id) return Boolean;
            --  Returns True if Sid is part of the aggregate lib project. That
            --  is, Sid project is one of the aggregated projects.

            ------------
            -- Is_Ada --
            ------------

            function Is_Ada (Sid : Source_Id) return Boolean is
            begin
               return Sid.Language /= null
                 and then Get_Name_String (Sid.Language.Name) = "ada";
            end Is_Ada;

            ------------------------------
            -- Is_Part_Of_Aggregate_Lib --
            ------------------------------

            function Is_Part_Of_Aggregate_Lib
              (Aggregate_Lib_Project :  Project_Id;
               Sid                   : Source_Id) return Boolean
            is
               P : Aggregated_Project_List :=
                     Aggregate_Lib_Project.Aggregated_Projects;
            begin
               while P /= null loop
                  if P.Project = Sid.Project then
                     return True;
                  end if;
                  P := P.Next;
               end loop;

               return False;
            end Is_Part_Of_Aggregate_Lib;

            Iter : Source_Iterator;
            Sid  : Source_Id;

         begin
            Iter :=
              (if Project.Qualifier = Aggregate_Library then
                 For_Each_Source (Tree, Locally_Removed => False)
               else For_Each_Source (Tree, Project, Locally_Removed => False));

            loop
               Sid := Element (Iter);
               exit when Sid = No_Source;

               Initialize_Source_Record (Sid);

               --  Skip sources that are removed/excluded and sources not
               --  part of the interface for standalone libraries.

               if (Project.Qualifier /= Aggregate_Library
                   or else (Is_Part_Of_Aggregate_Lib (Project, Sid)
                            and then Is_Install_Active (Sid.Project)))
                 and then (Project.Standalone_Library = No
                           or else Sid.Declared_In_Interfaces)
               then
                  if All_Sources then
                     Copy_Source (Sid);

                  elsif Sid.Naming_Exception = Yes then
                     --  When a naming exception is present for a body which
                     --  is not installed we must exclude the Naming from the
                     --  generated project.
                     Excluded_Naming.Include (Get_Name_String (Sid.Unit.Name));
                  end if;

                  --  Objects / Deps

                  if not Sources_Only
                    and then (Other_Part (Sid) = null or else Sid.Kind /= Spec)
                  then
                     if Copy (Object)
                       and then Sid.Kind /= Sep
                       and then Sid.Compilable = Yes
                     then
                        Copy_File
                          (From => Cat
                             (Get_Object_Directory
                                ((if Sid.Object_Project = No_Project
                                  then Sid.Project
                                  else Sid.Object_Project), False),
                              Sid.Object),
                           To   => Lib_Dir,
                           File => Get_Name_String (Sid.Object));
                     end if;

                     --  Only install Ada .ali files (always name the .ali
                     --  against the spec file).

                     if Copy (Dependency)
                       and then Sid.Kind /= Sep
                       and then Is_Ada (Sid)
                     then
                        declare
                           Proj : Project_Id := Sid.Project;
                           Ssid : Source_Id;
                        begin
                           Ssid :=
                             (if
                                Other_Part (Sid) = null
                                or else Sid.Naming_Exception = No
                                or else All_Sources
                              then Sid
                              else Other_Part (Sid));

                           if Project.Qualifier = Aggregate_Library then
                              Proj := Project;
                           end if;

                           Copy_File
                             (From => Cat
                                (Get_Object_Directory
                                  ((if Sid.Object_Project = No_Project
                                      or else Project.Qualifier =
                                        Aggregate_Library
                                    then Proj
                                    else Sid.Object_Project), Project.Library),
                                 Sid.Dep_Name),
                              To   => (if Proj.Library
                                       then ALI_Dir
                                       else Lib_Dir),
                              File => Get_Name_String (Ssid.Dep_Name));
                        end;
                     end if;
                  end if;
               end if;

               Next (Iter);
            end loop;
         end Copy_Project_Sources;

         -----------------
         -- Copy_Source --
         -----------------

         procedure Copy_Source (Sid : Source_Id) is
         begin
            if Copy (Source) and then Is_Install_Active (Sid.Project) then
               declare
                  Prep_Filename : constant String :=
                                    Cat
                                      (Get_Object_Directory
                                         (Sid.Project, False),
                                       Sid.File) & Prep_Suffix;
               begin
                  if not Source_Copied.Contains (Name_Id (Sid.Path.Name)) then
                     Source_Copied.Insert (Name_Id (Sid.Path.Name));

                     Copy_File
                       (From => (if Exists (Prep_Filename)
                                 then Prep_Filename
                                 else Get_Name_String (Sid.Path.Display_Name)),
                        To   => Sources_Dir,
                        File => Get_Name_String (Sid.Display_File));
                  end if;
               end;
            end if;
         end Copy_Source;

         --------------------
         -- Copy_Artifacts --
         --------------------

         procedure Copy_Artifacts
           (Pathname, Destination : String;
            Required              : Boolean)
         is

            procedure Copy_Entry (E : Directory_Entry_Type);
            --  Copy file pointed by E

            function Get_Directory (Fullname : String) return String;
            --  Returns the directory containing fullname. Note that we
            --  cannot use the standard Containing_Directory as filename
            --  can be a pattern and not be allowed in filename.

            function Get_Pattern return String;
            --  Return filename of pattern from Filename below

            Something_Copied : Boolean := False;
            --  Keep track if something has been copied or not. If an artifact
            --  is coming from Required_Artifacts we must ensure that there is
            --  actually something copied if we have a directory or wildcards.

            ----------------
            -- Copy_Entry --
            ----------------

            procedure Copy_Entry (E : Directory_Entry_Type) is
               Fullname : constant String := Full_Name (E);
               Dest_Dir : constant String :=
                            (if Is_Absolute_Path (Destination)
                             then Destination
                             else Prefix_Dir.V.all & Destination);
            begin
               if Kind (E) = Directory
                 and then Simple_Name (E) /= "."
                 and then Simple_Name (E) /= ".."
               then
                  Copy_Artifacts
                    (Fullname & "/*",
                     Dest_Dir & Simple_Name (E) & '/',
                     Required);

               elsif Kind (E) = Ordinary_File then
                  Copy_File
                    (From       => Fullname,
                     To         => Dest_Dir,
                     File       => Simple_Name (Fullname),
                     Executable => Is_Executable_File (Fullname));

                  if Required then
                     Something_Copied := True;
                  end if;
               end if;
            end Copy_Entry;

            -------------------
            -- Get_Directory --
            -------------------

            function Get_Directory (Fullname : String) return String is
               K : Natural := Fullname'Last;
            begin
               while K > 0
                 and then not Is_Directory_Separator (Fullname (K))
               loop
                  K := K - 1;
               end loop;

               pragma Assert (K > 0);

               return Fullname (Fullname'First .. K);
            end Get_Directory;

            -----------------
            -- Get_Pattern --
            -----------------

            function Get_Pattern return String is
               K : Natural := Pathname'Last;
            begin
               while K > 0
                 and then not Is_Directory_Separator (Pathname (K))
               loop
                  K := K - 1;
               end loop;

               return
                 (if K = 0 then Pathname
                  else Pathname (K + 1 .. Pathname'Last));
            end Get_Pattern;

         begin
            Ada.Directories.Search
              (Directory => Get_Directory (Pathname),
               Pattern   => Get_Pattern,
               Process   => Copy_Entry'Access);

            if Required and not Something_Copied then
               Rollback_Manifests;
               Fail_Program
                 (Project_Tree,
                  "error: file does not exist '" & Pathname & ''',
                  Flush_Messages => False);
            end if;
         exception
            when Text_IO.Name_Error =>
               if Required then
                  Rollback_Manifests;
                  Fail_Program
                    (Project_Tree,
                     "warning: file does not exist '" & Pathname & ''',
                     Flush_Messages => False);
               else
                  Put_Line
                    ("warning: file does not exist '" & Pathname & ''');
               end if;
         end Copy_Artifacts;

         procedure Copy_Interfaces is new For_Interface_Sources (Copy_Source);

         function Cat (Dir, File : String) return String is
           (if File = "" then "" else Dir & File);
         --  Returns Dir & File if File is not empty or "" otherwise

      begin
         if Has_Sources (Project) then
            --  Install the project and the extended projects if any

            declare
               P : Project_Id := Project;
            begin
               while P /= No_Project loop
                  if not All_Sources then
                     Copy_Interfaces (Tree, P);
                  end if;

                  Copy_Project_Sources (P);

                  P := P.Extends;
               end loop;
            end;
         end if;

         --  Copy library

         if Copy (Library) and not Sources_Only then
            if not Is_Static (Project)
              and then Project.Lib_Internal_Name /= No_Name
              and then Project.Library_Name /= Project.Lib_Internal_Name
            then
               if Windows_Target then
                  --  No support for version, do a simple copy

                  Copy_File
                    (From          => Cat
                       (Project.Library_Dir.Display_Name,
                        Get_Library_Filename),
                     To            => Lib_Dir,
                     File          => Get_Name_String (Get_Library_Filename),
                     Executable    => True,
                     Extract_Debug => Side_Debug);

               else
                  Copy_File
                    (From          => Cat
                       (Project.Library_Dir.Display_Name,
                        File_Name_Type (Project.Lib_Internal_Name)),
                     To            => Lib_Dir,
                     File          =>
                       Get_Name_String (Project.Lib_Internal_Name),
                     Executable    => True,
                     Extract_Debug => Side_Debug);

                  Copy_File
                    (From     => Lib_Dir
                                   & Get_Name_String (Get_Library_Filename),
                     To       => Lib_Dir,
                     File     => Get_Name_String (Project.Lib_Internal_Name),
                     From_Ver => Cat (Lib_Dir,
                        Major_Id_Name
                           (Get_Name_String (Get_Library_Filename),
                            Get_Name_String (Project.Lib_Internal_Name))),
                     Sym_Link => True);
               end if;

            else
               Copy_File
                 (From          => Cat
                    (Project.Library_Dir.Display_Name,
                     Get_Library_Filename),
                  To            => Lib_Dir,
                  File          => Get_Name_String (Get_Library_Filename),
                  Executable    => not Is_Static (Project),
                  Extract_Debug =>
                    Side_Debug and then not Is_Static (Project));
            end if;

            --  On Windows copy the shared libraries into the bin directory
            --  for it to be found in the PATH when running executable. On non
            --  Windows platforms add a symlink into the lib directory.

            if not Is_Static (Project) and then Add_Lib_Link then
               if Windows_Target then
                  if Lib_Dir /= Exec_Dir then
                     Copy_File
                       (From          => Lib_Dir
                        & Get_Name_String (Get_Library_Filename),
                        To            => Exec_Dir,
                        File          =>
                          Get_Name_String (Get_Library_Filename),
                        Executable    => True,
                        Extract_Debug => False);
                  end if;

               elsif Link_Lib_Dir /= Lib_Dir then
                  if On_Windows then
                     Copy_File
                       (From       => Lib_Dir
                          & Get_Name_String (Get_Library_Filename),
                        To         => Link_Lib_Dir,
                        File       => Get_Name_String (Get_Library_Filename),
                        Sym_Link   => False);
                  else
                     Copy_File
                       (From       => Link_Lib_Dir
                          & Get_Name_String (Get_Library_Filename),
                        To         => Lib_Dir,
                        File       => Get_Name_String (Get_Library_Filename),
                        Sym_Link   => True);
                  end if;
                  --  Copy also the versioned library if any

                  if Project.Lib_Internal_Name /= No_Name
                    and then Project.Library_Name /= Project.Lib_Internal_Name
                  then
                     if On_Windows then
                        Copy_File
                          (From       =>
                             Lib_Dir
                               & Get_Name_String (Project.Lib_Internal_Name),
                           To         => Link_Lib_Dir,
                           File       =>
                             Get_Name_String (Project.Lib_Internal_Name),
                           From_Ver   => Cat (Link_Lib_Dir,
                             Major_Id_Name
                               (Get_Name_String (Get_Library_Filename),
                                Get_Name_String (Project.Lib_Internal_Name))),
                           Sym_Link   => False);
                     else
                        Copy_File
                          (From       =>
                             Link_Lib_Dir
                               & Get_Name_String (Project.Lib_Internal_Name),
                           To         => Lib_Dir,
                           File       =>
                             Get_Name_String (Project.Lib_Internal_Name),
                           From_Ver   => Cat (Link_Lib_Dir,
                             Major_Id_Name
                               (Get_Name_String (Get_Library_Filename),
                                Get_Name_String (Project.Lib_Internal_Name))),
                           Sym_Link   => True);
                     end if;
                  end if;
               end if;
            end if;
         end if;

         --  Copy executable(s)

         if Copy (Executable) and not Sources_Only then
            Mains.Reset;

            declare
               M : Main_Info := Mains.Next_Main;
            begin
               while M /= No_Main_Info loop
                  if M.Project in Project | Project.Extends then
                     declare
                        Bin : constant String :=
                                Main_Binary (Name_Id (M.File));
                     begin
                        Copy_File
                          (From          =>
                             Get_Name_String
                               (Project.Exec_Directory.Display_Name) & Bin,
                           To            => Exec_Dir,
                           File          => Bin,
                           Executable    => True,
                           Extract_Debug => Side_Debug);
                     end;
                  end if;

                  M := Mains.Next_Main;
               end loop;
            end;
         end if;

         --  Copy artifacts

         for E of Artifacts loop
            declare
               Destination : constant String :=
                               Ensure_Directory
                                 (Get_Name_String (E.Destination));
               Filename    : constant String :=
                               Get_Name_String (E.Filename);
            begin
               Copy_Artifacts
                 (Get_Name_String (Project.Directory.Name) & Filename,
                  Destination,
                  E.Required);
            end;
         end loop;
      end Copy_Files;

      --------------------
      -- Create_Project --
      --------------------

      procedure Create_Project (Project : Project_Id) is

         Filename : constant String :=
                      Project_Dir
                      & Base_Name (Get_Name_String (Project.Path.Display_Name))
                      & ".gpr";

         Gprinstall_Tag : constant String :=
                            "This project has been generated by GPRINSTALL";

         Line    : Unbounded_String;

         function "+"
           (Item : String) return Unbounded_String renames To_Unbounded_String;
         function "-"
           (Item : Unbounded_String) return String renames To_String;

         procedure Create_Packages;
         --  Create packages that are needed, currently Naming and part of
         --  Linker is generated for the installed project.

         procedure Create_Variables;
         --  Create global variables

         function Image
           (Name : Name_Id;
            Id   : Array_Element_Id) return String;
         --  Returns Id image

         function Image (Id : Variable_Id) return String;
         --  Returns Id image

         function Image (Var : Variable_Value) return String;
         --  Returns Id image

         procedure Read_Project;
         --  Read project and set Content accordingly

         procedure Write_Project;
         --  Write content into project

         procedure Add_Empty_Line;
         pragma Inline (Add_Empty_Line);

         function Naming_Case_Alternative
           (Proj : Project_Id) return String_Vector.Vector;
         --  Returns the naming case alternative for this project configuration

         function Linker_Case_Alternative
           (Proj : Project_Id) return String_Vector.Vector;
         --  Returns the linker case alternative for this project configuration

         function Data_Attributes return String_Vector.Vector;
         --  Returns the attributes for the sources, objects and library

         function Get_Languages return String;
         --  Returns the list of languages

         function Get_Package
           (Project : Project_Id; Pkg_Name : Name_Id) return Package_Id;
         --  Returns the package Name for the given project

         function Get_Build_Line (Vars, Default : String) return String;
         --  Returns the build line for Var1 and possibly Var2 if not empty
         --  string. Default is the default build name.

         --------------------
         -- Add_Empty_Line --
         --------------------

         procedure Add_Empty_Line is
         begin
            if Content.Element (Content.Last_Index) /= "" then
               Content.Append ("");
            end if;
         end Add_Empty_Line;

         --------------------
         -- Get_Build_Line --
         --------------------

         function Get_Build_Line (Vars, Default : String) return String is
            use Strings.Fixed;
            Variables : String_Split.Slice_Set;
            Line      : Unbounded_String;
         begin
            Line := +"   BUILD : BUILD_KIND := ";

            if not No_Build_Var then
               String_Split.Create (Variables, Vars, ",");

               if Vars = "" then
                  --  No variable specified, use default value
                  Line := Line & "external(""";
                  Line := Line & To_Upper (Dir_Name (Suffix => False));
                  Line := Line & "_BUILD"", ";

               else
                  for K in 1 .. String_Split.Slice_Count (Variables) loop
                     Line := Line & "external(""";
                     Line := Line & String_Split.Slice (Variables, K) & """, ";
                  end loop;
               end if;
            end if;

            Line := Line & '"' & Default & '"';

            if not No_Build_Var then
               Line := Line
                 & (+(Natural (String_Split.Slice_Count (Variables)) * ')'));
            end if;

            Line := Line & ';';

            return -Line;
         end Get_Build_Line;

         ---------------------
         -- Create_Packages --
         ---------------------

         procedure Create_Packages is

            procedure Create_Naming (Proj : Project_Id);
            --  Create the naming package

            procedure Create_Linker (Proj : Project_Id);
            --  Create the linker package if needed

            -------------------
            -- Create_Naming --
            -------------------

            procedure Create_Naming (Proj : Project_Id) is
               P : constant Package_Id := Get_Package (Proj, Name_Naming);
            begin
               Content.Append ("   package Naming is");

               if P /= No_Package then
                  --  Attributes

                  declare
                     V : Variable_Id := Pcks (P).Decl.Attributes;
                  begin
                     while V /= No_Variable loop
                        Content.Append ("      " & Image (V));
                        V := Vels (V).Next;
                     end loop;
                  end;
               end if;

               Content.Append ("      case BUILD is");

               if P /= No_Package then
                  Content.Append_Vector (Naming_Case_Alternative (Proj));
               end if;

               Content.Append ("      end case;");
               Content.Append ("   end Naming;");
               Add_Empty_Line;
            end Create_Naming;

            -------------------
            -- Create_Linker --
            -------------------

            procedure Create_Linker (Proj : Project_Id) is
               P : constant Package_Id := Get_Package (Proj, Name_Linker);
            begin
               Content.Append ("   package Linker is");

               Content.Append ("      case BUILD is");
               --  Attribute Linker_Options only if set

               if P /= No_Package then
                  Content.Append_Vector (Linker_Case_Alternative (Proj));
               end if;

               Content.Append ("      end case;");
               Content.Append ("   end Linker;");
               Add_Empty_Line;
            end Create_Linker;

         begin
            Create_Naming (Project);
            Create_Linker (Project);
         end Create_Packages;

         ----------------------
         -- Create_Variables --
         ----------------------

         procedure Create_Variables is
            Vars    : Variable_Id;
            Types   : Type_Node_Ref := null;
            Current : Type_Node_Ref;
            Max_Len : Natural := 0;

         begin
            Vars := Project.Decl.Variables;

            Var_Loop : while Vars /= No_Variable loop
               declare
                  V : constant Variable := Vels (Vars);
               begin
                  --  Compute variable's name maximum length

                  if V.Value.Kind in Single | List then
                     Max_Len := Natural'Max
                       (Max_Len, Get_Name_String (V.Name)'Length);
                  end if;

                  --  Check if a typed variable

                  if GPR.Tree.Present (V.Value.String_Type) then
                     Current := Types;

                     Type_Loop : while Current /= null loop
                        exit Type_Loop when
                          Current.String_Type = V.Value.String_Type;
                        Current := Current.Next;
                     end loop Type_Loop;

                     if Current = null then
                        Types := new Type_Node'
                          (String_Type => V.Value.String_Type,
                           Next        => Types);
                     end if;
                  end if;

                  Vars := V.Next;
               end;
            end loop Var_Loop;

            --  Output the types if any

            Current := Types;
            while Current /= null loop
               Pretty_Print
                 (Project                            => Current.String_Type,
                  In_Tree                            => Node_Tree,
                  Increment                          => 2,
                  Eliminate_Empty_Case_Constructions => False,
                  Minimize_Empty_Lines               => False,
                  W_Char                             => Write_Char'Access,
                  W_Eol                              => Write_Eol'Access,
                  W_Str                              => Write_Str'Access,
                  Backward_Compatibility             => False,
                  Id                                 => No_Project,
                  Max_Line_Length                    => 79,
                  Initial_Indent                     => 3);
               Write_Eol;

               Current := Current.Next;
            end loop;

            --  Finally output variables

            Vars := Project.Decl.Variables;
            while Vars /= No_Variable loop
               declare
                  V : constant Variable := Vels (Vars);
               begin
                  if V.Value.Kind in Single | List then
                     Write_Str ("   " & Get_Name_String (V.Name));
                     Write_Str
                       (To_String
                          ((Max_Len - Get_Name_String (V.Name)'Length) * ' '));

                     if GPR.Tree.Present (V.Value.String_Type) then
                        Write_Str (" : ");
                        Write_Str
                          (Get_Name_String
                             (GPR.Tree.Name_Of
                                (V.Value.String_Type, Node_Tree)));
                     end if;

                     Write_Str (" := " & Image (V.Value));
                     Write_Eol;
                  end if;
                  Vars := V.Next;
               end;
            end loop;
         end Create_Variables;

         ---------------------
         -- Data_Attributes --
         ---------------------

         function Data_Attributes return String_Vector.Vector is

            procedure Gen_Dir_Name
              (P : Param; Line : in out Unbounded_String);
            --  Generate dir name

            ------------------
            -- Gen_Dir_Name --
            ------------------

            procedure Gen_Dir_Name
              (P : Param; Line : in out Unbounded_String) is
            begin
               if P.Default then
                  --  This is the default value, add Dir_Name
                  Line := Line & Dir_Name (Suffix => False);

                  --  Furthermore, if the build name is "default" do not output

                  if Build_Name.all /= "default" then
                     Line := Line & "." & Build_Name.all;
                  end if;
               end if;
            end Gen_Dir_Name;

            V    : String_Vector.Vector;
            Line : Unbounded_String;
         begin
            V.Append ("      when """ & Build_Name.all & """ =>");

            --  Project sources

            Line := +"         for Source_Dirs use (""";

            if Has_Sources (Project) then
               Line := Line
                 & Relative_Path
                 (Sources_Dir (Build_Name => False), To => Project_Dir);

               Gen_Dir_Name (Sources_Subdir, Line);
            end if;

            Line := Line & """);";

            V.Append (-Line);

            --  Project objects and/or library

            Line :=
              (if Project.Library then +"         for Library_Dir use """
               else +"         for Object_Dir use """);

            Line := Line
              & Relative_Path
                  (Lib_Dir (Build_Name => False), To => Project_Dir);

            Gen_Dir_Name (Lib_Subdir, Line);
            Line := Line & """;";

            V.Append (-Line);

            if Project.Library then
               --  If ALI are in a different location, set the corresponding
               --  attribute.

               if Lib_Dir /= ALI_Dir then
                  Line := +"         for Library_ALI_Dir use """;

                  Line := Line
                    & Relative_Path
                    (ALI_Dir (Build_Name => False), To => Project_Dir);

                  Gen_Dir_Name (ALI_Subdir, Line);
                  Line := Line & """;";
                  V.Append (-Line);
               end if;

               Line := +"         for Library_Kind use """;
               Line := Line & Image (Project.Library_Kind);
               Line := Line & """;";
               V.Append (-Line);

               if Project.Standalone_Library /= No then
                  if not Is_Static (Project) then
                     Line := +"         for Library_Standalone use """;
                     Line := Line & To_Lower
                       (Standalone'Image (Project.Standalone_Library));
                     Line := Line & """;";
                     V.Append (-Line);
                  end if;

                  --  And then generates the interfaces

                  declare
                     First : Boolean := True;

                     V     : constant Variable_Value :=
                               Value_Of (Name_Interfaces,
                                         Project.Decl.Attributes,
                                         Tree.Shared);

                     procedure Source_Interface (Source : Source_Id);

                     ----------------------
                     -- Source_Interface --
                     ----------------------

                     procedure Source_Interface (Source : Source_Id) is
                     begin
                        if Source.Unit /= No_Unit_Index then
                           if not First then
                              Append (Line, ", ");
                           else
                              First := False;
                           end if;

                           Append (Line, """");
                           Append (Line, Get_Name_String (Source.Unit.Name));
                           Append (Line, """");
                        end if;
                     end Source_Interface;

                     procedure List_Interfaces is
                       new For_Interface_Sources (Source_Interface);

                  begin
                     if V /= Nil_Variable_Value
                       and then not V.Default
                       and then V.Values /= Nil_String
                     then
                        Line := +"         for Interfaces use ";

                        pragma Assert (V.Kind = List);

                        Append (Line, Image (V));

                     else
                        Line := +"         for Library_Interface use (";

                        List_Interfaces (Tree, Project);

                        Append (Line, ");");
                     end if;
                  end;

                  V.Append (-Line);
               end if;
            end if;

            return V;
         end Data_Attributes;

         -------------------
         -- Get_Languages --
         -------------------

         function Get_Languages return String is

            package Lang_Set is new Containers.Indefinite_Ordered_Sets
              (String,
               Strings.Less_Case_Insensitive, Strings.Equal_Case_Insensitive);

            Langs : Lang_Set.Set;

            procedure For_Project (Project : Project_Id);
            --  Add languages for the given project

            -----------------
            -- For_Project --
            -----------------

            procedure For_Project (Project : Project_Id) is
               L : Language_Ptr := Project.Languages;
            begin
               while L /= null loop
                  if L.Config.Compiler_Driver /= No_File
                    and then Get_Name_String (L.Config.Compiler_Driver) /= ""
                  then
                     Langs.Include (Get_Name_String (L.Display_Name));
                  end if;
                  L := L.Next;
               end loop;
            end For_Project;

         begin
            --  First adds language for the main project

            For_Project (Project);

            --  If we are dealing with an aggregate library, adds the languages
            --  from all aggregated projects.

            if Project.Qualifier = Aggregate_Library then
               declare
                  Agg : Aggregated_Project_List := Project.Aggregated_Projects;
               begin
                  while Agg /= null loop
                     For_Project (Agg.Project);
                     Agg := Agg.Next;
                  end loop;
               end;
            end if;

            declare
               Res   : Unbounded_String;
               First : Boolean := True;
            begin
               for V of Langs loop
                  if not First then
                     Res := Res & ", ";
                  end if;

                  Res := Res & '"' & V & '"';

                  First := False;
               end loop;

               return To_String (Res);
            end;
         end Get_Languages;

         -----------------
         -- Get_Package --
         -----------------

         function Get_Package
           (Project : Project_Id; Pkg_Name : Name_Id) return Package_Id
         is
            Pck : Package_Id := Project.Decl.Packages;
         begin
            while Pck /= No_Package loop
               if Pcks (Pck).Decl /= No_Declarations
                 and then Pcks (Pck).Name = Pkg_Name
               then
                  return Pck;
               end if;

               Pck := Pcks (Pck).Next;
            end loop;
            return No_Package;
         end Get_Package;

         -----------
         -- Image --
         -----------

         function Image
           (Name : Name_Id;
            Id   : Array_Element_Id) return String
         is
            E : constant Array_Element :=
                  Tree.Shared.Array_Elements.Table (Id);
         begin
            return "for " & Get_Name_String (Name)
              & " ("""  & Get_Name_String (E.Index)
              & """) use " & Image (E.Value);
         end Image;

         function Image (Id : Variable_Id) return String is
            V : constant Variable_Value := Vels (Id).Value;
         begin
            return
              (if V.Default then ""
               else "for " & Get_Name_String (Vels (Id).Name) & " use " &
                 Image (V));
         end Image;

         function Image (Var : Variable_Value) return String is
         begin
            case Var.Kind is
               when Single =>
                  return '"' & Get_Name_String (Var.Value) & '"'
                    & (if Var.Index = 0 then "" else " at" & Var.Index'Img)
                    & ';';

               when List =>
                  declare
                     V     : Unbounded_String;
                     L     : String_List_Id := Var.Values;
                     First : Boolean := True;
                  begin
                     Append (V, "(");

                     while L /= Nil_String loop
                        if not First then
                           Append (V, ", ");
                        else
                           First := False;
                        end if;

                        Append
                          (V, '"' & Get_Name_String (Strs (L).Value) & '"');

                        if Strs (L).Index > 0 then
                           Append (V, " at" & Strs (L).Index'Img);
                        end if;

                        L := Strs (L).Next;
                     end loop;
                     Append (V, ");");

                     return To_String (V);
                  end;

               when Undefined =>
                  return "";
            end case;
         end Image;

         -----------------------------
         -- Linker_Case_Alternative --
         -----------------------------

         function Linker_Case_Alternative
           (Proj : Project_Id) return String_Vector.Vector
         is
            use type Ada.Containers.Count_Type;

            procedure Linker_For (Pck : Package_Id);
            --  Handle the linker options for this package

            procedure Append (Values : String_List_Id);
            --  Add values if any

            procedure Add_Library_Options (Proj : Project_Id);
            --  For a library project, add the Library_Options

            procedure Opts_Append (Opt : String);
            --  Add options only if it was not appended before into Opts

            Seen : Seen_Set.Set;
            --  Records the attribute generated to avoid duplicate when
            --  handling aggregated projects.

            R    : String_Vector.Vector;
            Opts : String_Vector.Vector;

            -------------------------
            -- Add_Library_Options --
            -------------------------

            procedure Add_Library_Options (Proj : Project_Id) is
            begin
               if Proj.Library then
                  declare
                     V : constant Variable_Value :=
                           Value_Of (Name_Library_Options,
                                     Proj.Decl.Attributes,
                                     Tree.Shared);
                  begin
                     if V /= Nil_Variable_Value then
                        Append (V.Values);
                     end if;
                  end;
               end if;
            end Add_Library_Options;

            -----------------
            -- Opts_Append --
            -----------------

            procedure Opts_Append (Opt : String) is
               Position : Seen_Set.Cursor;
               Inserted : Boolean;
            begin
               Seen.Insert (Opt, Position, Inserted);

               if Inserted then
                  Opts.Append (Opt);
               end if;
            end Opts_Append;

            ------------
            -- Append --
            ------------

            procedure Append (Values : String_List_Id) is
               L : String_List_Id := Values;
            begin
               while L /= Nil_String loop
                  Opts_Append (Get_Name_String (Strs (L).Value));
                  L := Strs (L).Next;
               end loop;
            end Append;

            ----------------
            -- Linker_For --
            ----------------

            procedure Linker_For (Pck : Package_Id) is
               V : Variable_Id := Pcks (Pck).Decl.Attributes;
            begin
               while V /= No_Variable loop
                  if Vels (V).Name = Name_Linker_Options then
                     Append (Vels (V).Value.Values);
                  end if;

                  V := Vels (V).Next;
               end loop;
            end Linker_For;

         begin
            R.Append ("         when """ & Build_Name.all & """ =>");

            Linker_For (Get_Package (Proj, Name_Linker));

            --  For libraries we want to add the library options here

            Add_Library_Options (Proj);

            if Proj.Qualifier = Aggregate_Library then
               declare
                  Agg : Aggregated_Project_List :=
                          Project.Aggregated_Projects;
               begin
                  while Agg /= null loop
                     Linker_For (Get_Package (Agg.Project, Name_Linker));

                     --  Likewise for all aggregated libraries

                     Add_Library_Options (Agg.Project);

                     Agg := Agg.Next;
                  end loop;
               end;
            end if;

            --  We also want to add the externally built libraries without
            --  sources (referencing system libraries for example).

            declare
               L : Project_List := Project.All_Imported_Projects;
            begin
               while L /= null loop
                  if L.Project.Library
                    and then L.Project.Externally_Built
                    and then not Bring_Sources (L.Project)
                  then
                     Opts_Append
                       ("-L" & Get_Name_String (L.Project.Library_Dir.Name));
                     Opts_Append
                       ("-l" & Get_Name_String (L.Project.Library_Name));
                  end if;

                  L := L.Next;
               end loop;
            end;

            if Opts.Length = 0 then
               --  No linker alternative found, add null statement
               R.Append ("            null;");

            else
               declare
                  O_List : Unbounded_String;
               begin
                  for O of Opts loop
                     if O_List /= Null_Unbounded_String then
                        Append (O_List, ", ");
                     end if;

                     Append (O_List, '"' & O & '"');
                  end loop;

                  R.Append
                    ("            for Linker_Options use ("
                     & To_String (O_List) & ");");
               end;
            end if;

            return R;
         end Linker_Case_Alternative;

         -----------------------------
         -- Naming_Case_Alternative --
         -----------------------------

         function Naming_Case_Alternative
           (Proj : Project_Id) return String_Vector.Vector
         is
            procedure Naming_For (Pck : Package_Id);
            --  Handle the naming scheme for this package

            function Is_Language_Active (Lang : String) return Boolean;
            --  Returns True if Lang is active in the installed project

            Seen : Seen_Set.Set;
            --  Records the attribute generated to avoid duplicate when
            --  handling aggregated projects.

            V    : String_Vector.Vector;
            --  Contains the final result returned

            Languages : constant String :=
                          Characters.Handling.To_Lower (Get_Languages);
            --  Languages for the generated projects

            ------------------------
            -- Is_Language_Active --
            ------------------------

            function Is_Language_Active (Lang : String) return Boolean is
            begin
               return Strings.Fixed.Index
                 (Languages,
                  Characters.Handling.To_Lower (Lang)) /= 0;
            end Is_Language_Active;

            ----------------
            -- Naming_For --
            ----------------

            procedure Naming_For (Pck : Package_Id) is
               A    : Array_Id := Pcks (Pck).Decl.Arrays;
               N, I : Name_Id;
               E    : Array_Element_Id;
            begin
               --  Arrays

               while A /= No_Array loop
                  N := Tree.Shared.Arrays.Table (A).Name;
                  E := Tree.Shared.Arrays.Table (A).Value;
                  I := Tree.Shared.Array_Elements.Table (E).Index;

                  while E /= No_Array_Element loop
                     --  Check if this naming is not to be filtered-out. This
                     --  is a special case when a renaming is given for a
                     --  body. See Excluded_Name comments.

                     if (N /= Name_Body
                         or else
                           not Excluded_Naming.Contains (Get_Name_String (I)))
                       and then
                         (N not in Name_Spec_Suffix
                                 | Name_Body_Suffix
                                 | Name_Separate_Suffix
                          or else Is_Language_Active
                            (Get_Name_String
                               (Tree.Shared.Array_Elements.Table (E).Index)))
                     then
                        declare
                           Decl : constant String := Image (N, E);
                        begin
                           if not Seen.Contains (Decl) then
                              V.Append ("            " & Decl);
                              Seen.Include (Decl);
                           end if;
                        end;
                     end if;

                     E := Tree.Shared.Array_Elements.Table (E).Next;
                  end loop;

                  A := Tree.Shared.Arrays.Table (A).Next;
               end loop;
            end Naming_For;

         begin
            V.Append ("         when """ & Build_Name.all & """ =>");

            Naming_For (Get_Package (Proj, Name_Naming));

            if Proj.Qualifier = Aggregate_Library then
               declare
                  Agg : Aggregated_Project_List :=
                          Project.Aggregated_Projects;
               begin
                  while Agg /= null loop
                     Naming_For (Get_Package (Agg.Project, Name_Naming));
                     Agg := Agg.Next;
                  end loop;
               end;
            end if;

            return V;
         end Naming_Case_Alternative;

         ------------------
         -- Read_Project --
         ------------------

         procedure Read_Project is
            Max_Buffer : constant := 1_024;
            File       : File_Type;
            Buffer     : String (1 .. Max_Buffer);
            Last       : Natural;
         begin
            Open (File, In_File, Filename);

            while not End_Of_File (File) loop
               declare
                  L : Unbounded_String;
               begin
                  loop
                     Get_Line (File, Buffer, Last);
                     Append (L, Buffer (1 .. Last));
                     exit when Last < Max_Buffer
                       or else End_Of_Line (File);
                  end loop;

                  Content.Append (To_String (L));
               end;
            end loop;

            Close (File);
         end Read_Project;

         -------------------
         -- Write_Project --
         -------------------

         procedure Write_Project is
            F    : File_Access := Standard_Output;
            File : aliased File_Type;
         begin
            if not Dry_Run then
               if not Exists (Project_Dir) then
                  Create_Path (Project_Dir);
               end if;

               Create (File, Out_File, Filename);
               F := File'Unchecked_Access;
            end if;

            for K in Content.First_Index .. Content.Last_Index loop
               Put_Line (F.all, Content.Element (K));
            end loop;

            if not Dry_Run then
               Close (File);
            end if;
         end Write_Project;

         type Section_Kind is (Top, Naming, Linker);

         Project_Exists  : constant Boolean := Exists (Filename);
         Current_Section : Section_Kind := Top;
         Pos             : String_Vector.Cursor;
         Generated       : Boolean := False;

      begin
         if Dry_Run or else Opt.Verbose_Mode then
            New_Line;
            Put ("Project ");
            Put (Filename);

            Put_Line
              ((if Dry_Run then " would be installed" else " installed"));

            New_Line;
         end if;

         --  If project exists, read it and check the generated status

         if Project_Exists then
            Read_Project;

            --  First check that this project has been generated by gprbuild,
            --  if not exit with an error as we cannot modify a project created
            --  manually and we do not want to overwrite it.

            Pos := Content.First;

            Check_Generated_Status :
            while String_Vector.Has_Element (Pos) loop
               if Fixed.Index
                 (String_Vector.Element (Pos), Gprinstall_Tag) /= 0
               then
                  Generated := True;
                  exit Check_Generated_Status;
               end if;
               String_Vector.Next (Pos);
            end loop Check_Generated_Status;

            if not Generated and then not Force_Installations then
               Put ("non gprinstall project file ");
               Put (Filename);
               Put (" exists, use -f to overwrite");
               New_Line;
               Finish_Program (Project_Tree, E_Fatal);
            end if;
         end if;

         if Project_Exists and then Generated then
            if not Has_Sources (Project) then
               --  Nothing else to do in this case
               return;
            end if;

            if Opt.Verbose_Mode then
               Put_Line ("project file exists, merging new build");
            end if;

            --  Do merging for new build, we need to add an entry into the
            --  BUILD_KIND type and a corresponding case entry in the naming
            --  and Linker package.

            Parse_Content :
            while String_Vector.Has_Element (Pos) loop
               declare
                  BN   : constant String := Build_Name.all;
                  Line : constant String := String_Vector.Element (Pos);
                  P, L : Natural;
               begin
                  if Fixed.Index (Line, "type BUILD_KIND is (") /= 0 then
                     --  This is the "type BUILD_KIND" line, add new build name

                     --  First check if the current build name already exists

                     if Fixed.Index (Line, """" & BN & """") = 0 then
                        --  Get end of line

                        P := Fixed.Index (Line, ");");

                        if P = 0 then
                           Fail_Program
                             (Project_Tree,
                              "cannot parse the BUILD_KIND line");

                        else
                           Content.Replace_Element
                             (Pos,
                              Line (Line'First .. P - 1)
                              & ", """ & BN & """);");
                        end if;
                     end if;

                  elsif Fixed.Index (Line, ":= external(") /= 0 then

                     --  This is the BUILD line, get build vars

                     declare
                        Default : Unbounded_String;
                     begin
                        --  Get default value

                        L := Fixed.Index
                          (Line, """", Going => Strings.Backward);
                        P := Fixed.Index
                          (Line (Line'First .. L - 1), """",
                           Going => Strings.Backward);

                        Default := +Line (P + 1 .. L - 1);

                        Content.Replace_Element
                          (Pos,
                           Get_Build_Line
                             ((if Build_Vars = null
                              then ""
                              else Build_Vars.all), -Default));
                     end;

                  elsif Fixed.Index (Line, "package Naming is") /= 0 then
                     Current_Section := Naming;

                  elsif Fixed.Index (Line, "package Linker is") /= 0 then
                     Current_Section := Linker;

                  elsif Fixed.Index (Line, "case BUILD is") /= 0 then

                     --  Add new case section for the new build name

                     case Current_Section is
                        when Naming =>
                           String_Vector.Next (Pos);
                           Content.Insert_Vector
                             (Pos, Naming_Case_Alternative (Project));

                        when Linker =>
                           String_Vector.Next (Pos);
                           Content.Insert_Vector
                             (Pos, Linker_Case_Alternative (Project));

                        when Top =>
                           --  For the Sources/Lib attributes
                           String_Vector.Next (Pos);
                           Content.Insert_Vector (Pos, Data_Attributes);
                     end case;

                  elsif Fixed.Index (Line, "when """ & BN & """ =>") /= 0 then
                     --  Found a when with the current build name, this is a
                     --  previous install overwritten by this one. Remove this
                     --  section. Note that this removes sections from all
                     --  packages Naming and Linker, and from project level
                     --  case alternative.

                     Count_And_Delete : declare

                        use type Containers.Count_Type;

                        function End_When (L : String) return Boolean;
                        --  Return True if L is the end of a when alternative

                        --------------
                        -- End_When --
                        --------------

                        function End_When (L : String) return Boolean is
                           P   : constant Natural :=
                                   Strings.Fixed.Index_Non_Blank (L);
                           Len : constant Natural := L'Length;
                        begin
                           return P > 0
                             and then
                               ((P + 4 <= Len
                                 and then L (P .. P + 4) = "when ")
                                or else
                                  (P + 8 <= Len
                                   and then L (P .. P + 8) = "end case;"));
                        end End_When;

                        N : Containers.Count_Type := 0;
                        P : String_Vector.Cursor := Pos;
                     begin
                        --  The number of line to delete are from Pos to the
                        --  first line starting with a "when".

                        loop
                           String_Vector.Next (P);
                           N := N + 1;

                           exit when End_When (String_Vector.Element (P));
                        end loop;

                        Content.Delete (Pos, N);
                     end Count_And_Delete;
                  end if;
               end;

               String_Vector.Next (Pos);
            end loop Parse_Content;

         else
            --  Project does not exist, or it exists, was not generated by
            --  gprinstall and -f used. In this case it will be overwritten by
            --  a generated project.

            Content.Clear;

            --  Tag project as generated by gprbuild

            Content.Append
              ("--  " & Gprinstall_Tag & ' ' & Gpr_Version_String);
            Add_Empty_Line;

            --  Handle with clauses, generate a with clauses only for project
            --  bringing some visibility to sources. No need for doing this for
            --  aggregate projects.

            if Project.Qualifier /= Aggregate_Library then
               declare
                  L : Project_List := Project.Imported_Projects;
               begin
                  while L /= null loop
                     if Has_Sources (L.Project)
                       and then Is_Install_Active (L.Project)
                     then
                        Content.Append
                          ("with """
                          & Base_Name
                            (Get_Name_String (L.Project.Path.Display_Name))
                          & """;");
                     end if;

                     L := L.Next;
                  end loop;
               end;
            end if;

            --  In all cases adds externally built projects

            declare
               L : Project_List := Project.All_Imported_Projects;
            begin
               while L /= null loop
                  if Has_Sources (L.Project)
                    and then L.Project.Externally_Built
                  then
                     Content.Append
                       ("with """
                        & Base_Name
                          (Get_Name_String (L.Project.Path.Display_Name))
                        & """;");
                  end if;

                  L := L.Next;
               end loop;
            end;

            Add_Empty_Line;

            --  Project name

            if Project.Library then
               Line := +"library ";
            else
               Line :=
                 (if Has_Sources (Project) then +"standard "
                  else +"abstract ");
            end if;

            Line := Line & "project ";
            Line := Line & Get_Name_String (Project.Display_Name);
            Line := Line & " is";
            Content.Append (-Line);

            if Has_Sources (Project) or Project.Library then
               --  BUILD variable

               Content.Append
                 ("   type BUILD_KIND is (""" & Build_Name.all & """);");

               Line := +Get_Build_Line
                 (Vars    =>
                    (if Build_Vars = null then "" else Build_Vars.all),
                  Default => Build_Name.all);

               Content.Append (-Line);

               --  Add languages, for an aggregate library we want all unique
               --  languages from all aggregated libraries.

               if Has_Sources (Project) then
                  Add_Empty_Line;

                  Content.Append
                    ("   for Languages use (" & Get_Languages & ");");
               end if;

               --  Build_Suffix used to avoid .default as suffix

               Add_Empty_Line;

               Content.Append ("   case BUILD is");
               Content.Append_Vector (Data_Attributes);
               Content.Append ("   end case;");

               Add_Empty_Line;

               --  Library Name

               if Project.Library then
                  Content.Append
                    ("   for Library_Name use """
                     & Get_Name_String (Project.Library_Name)
                     & """;");

                  --  Issue the Library_Version only if needed

                  if not Is_Static (Project)
                    and then Project.Lib_Internal_Name /= No_Name
                    and then Project.Library_Name /= Project.Lib_Internal_Name
                  then
                     Content.Append
                       ("   for Library_Version use """
                        & Get_Name_String (Project.Lib_Internal_Name)
                        & """;");
                  end if;
               end if;

               --  Packages

               if Has_Sources (Project) then
                  Add_Empty_Line;

                  Create_Packages;
               end if;

               --  Set as not installable

               Add_Empty_Line;

               Content.Append ("   package Install is");
               Content.Append ("      for Active use ""False"";");
               Content.Append ("   end Install;");

               --  Externally Built

               if not Sources_Only then
                  Add_Empty_Line;
                  Content.Append ("   for Externally_Built use ""True"";");
               end if;

            else
               --  This is an abstract project

               Content.Append ("   for Source_Dirs use ();");
            end if;

            --  Variables

            Add_Empty_Line;
            Create_Variables;

            --  Close project

            Content.Append
              ("end " & Get_Name_String (Project.Display_Name) & ";");
         end if;

         --  Write new project if needed

         Write_Project;

         if not Dry_Run and then Install_Manifest then
            --  Add project file to manifest

            Add_To_Manifest (Filename);
         end if;
      end Create_Project;

      -------------------------
      -- Open_Check_Manifest --
      -------------------------

      procedure Open_Check_Manifest
        (File : out Text_IO.File_Type; Current_Line : out Text_IO.Count)
      is
         Dir     : constant String := Project_Dir & "manifests";
         Name    : constant String := Dir & DS & Install_Name.V.all;
         Prj_Sig : constant String :=
                     File_MD5 (Get_Name_String (Project.Path.Display_Name));
         Buf     : String (1 .. 128);
         Last    : Natural;
      begin
         --  Check whether the manifest does not exist in this case

         if Exists (Name) then
            --  If this manifest is the same of the current aggregate
            --  one, do not try to reopen it.

            if not Is_Open (Agg_Manifest)
              or else Normalize_Pathname
                        (Text_IO.Name (Agg_Manifest),
                         Case_Sensitive => False)
                      /= Normalize_Pathname (Name, Case_Sensitive => False)
            then
               Open (File, In_File, Name);
               Get_Line (File, Buf, Last);

               if Last >= Message_Digest'Length
                 and then
                   (Buf (1 .. 2) /= Sig_Line
                    or else Buf (3 .. Message_Digest'Last + 2) /= Prj_Sig)
                 and then Install_Name.Default
                 and then Install_Project
               then
                  Put_Line
                    ("Project already installed, either:");
                  Put_Line
                    ("   - uninstall first using --uninstall option");
                  Put_Line
                    ("   - install under another name, use --install-name");
                  Put_Line
                    ("   - force installation under the same name, "
                     & "use --install-name=" & Install_Name.V.all);
                  Finish_Program (Project_Tree, E_Fatal);
               end if;

               Reset (File, Append_File);

               Current_Line := Line (File);
            end if;

         else
            Create_Path (Dir);
            Create (File, Out_File, Name);
            Current_Line := 1;

            Put_Line (File, Sig_Line & Prj_Sig);
         end if;

      exception
         when Text_IO.Use_Error =>
            Put_Line
              ("cannot open or create the manifest file "
               & Project_Subdir.V.all & Install_Name.V.all);
            Put_Line ("check permissions on this location");
            Finish_Program (Project_Tree, E_Fatal);
      end Open_Check_Manifest;

      ------------------------
      -- Rollback_Manifests --
      ------------------------

      procedure Rollback_Manifests is

         Content : String_Vector.Vector;

         procedure Rollback_Manifest
           (File : in out Text_IO.File_Type; Line : Text_IO.Count);

         -----------------------
         -- Rollback_Manifest --
         -----------------------

         procedure Rollback_Manifest
           (File : in out Text_IO.File_Type; Line : Text_IO.Count)
         is
            use type Ada.Containers.Count_Type;
            Dir    : constant String :=
                       Containing_Directory (Name (File)) & DS;
            Buffer : String (1 .. 4_096);
            Last   : Natural;
         begin
            --  Set manifest file in Read mode

            Reset (File, Text_IO.In_File);

            while not End_Of_File (File) loop
               Get_Line (File, Buffer, Last);

               if Text_IO.Line (File) = 2
                 or else Text_IO.Line (File) < Line
               then
                  --  Record file to be kept in manifest
                  Content.Append (Buffer (1 .. Last));

               else
                  --  Delete file
                  declare
                     Filename : constant String :=
                                  Dir
                                  & Buffer
                                      (GNAT.MD5.Message_Digest'Length + 2
                                        .. Last);
                  begin
                     Ada.Directories.Delete_File (Filename);

                     Delete_Empty_Directory
                       (Prefix_Dir.V.all, Containing_Directory (Filename));
                  end;
               end if;
            end loop;

            --  There is nothing left in the manifest file (only the signature
            --  line), remove it, otherwise we create the new manifest file
            --  containing only the previous content.

            if Content.Length = 1 then
               declare
                  Manifest_Filename : constant String := Name (File);
               begin
                  Delete (File);

                  --  Delete manifest directories if empty

                  Delete_Empty_Directory
                    (Prefix_Dir.V.all,
                     Containing_Directory (Manifest_Filename));
               end;

            else
               --  Set manifest file back to Write mode

               Reset (File, Text_IO.Out_File);

               for C of Content loop
                  Text_IO.Put_Line (File, C);
               end loop;

               Close (File);
            end if;
         end Rollback_Manifest;

      begin
         if Is_Open (Man) then
            Rollback_Manifest (Man, Line_Manifest);
         end if;

         if Is_Open (Agg_Manifest) then
            Rollback_Manifest (Agg_Manifest, Line_Agg_Manifest);
         end if;
      end Rollback_Manifests;

      Is_Project_To_Install : Boolean;
      --  Whether the project is to be installed

   begin
      --  Empty Content

      Content.Delete_First (Count => Ada.Containers.Count_Type'Last);

      --  First look for the Install package and set up the local values
      --  accordingly.

      Check_Install_Package;

      --  The default install name is the name of the project without
      --  extension.

      if Install_Name.Default then
         Install_Name.V :=
           new String'((Base_Name (Get_Name_String (Project.Path.Name))));
      end if;

      --  Skip non active project and externally built ones

      Is_Project_To_Install := Active
        and (Bring_Sources (Project)
             or Project.Externally_Built);

      --  If we have an aggregate project we just install separately all
      --  aggregated projects.

      if Project.Qualifier = Aggregate then
         --  If this is the main project and is an aggregate project, create
         --  the corresponding manifest.

         if Project = Main_Project
           and then Main_Project.Qualifier = Aggregate
           and then Install_Manifest
         then
            Open_Check_Manifest (Agg_Manifest, Line_Agg_Manifest);
         end if;

         declare
            L : Aggregated_Project_List := Project.Aggregated_Projects;
         begin
            while L /= null loop
               Process (L.Tree, L.Node_Tree, L.Project);
               L := L.Next;
            end loop;
         end;

         --  Nothing more to do for an aggregate project

         return;
      end if;

      if not Installed.Contains (Project.Name) then
         Installed.Include (Project.Name);

         if not Opt.Quiet_Output then
            if Is_Project_To_Install then
               Put ("Install");
            elsif Opt.Verbose_Mode then
               Put ("Skip");
            end if;

            if Is_Project_To_Install or Opt.Verbose_Mode then
               Put (" project ");
               Put (Get_Name_String (Project.Display_Name));
               if Build_Name.all /= "default" then
                  Put (" - " & Build_Name.all);
               end if;
            end if;

            if not Is_Project_To_Install and Opt.Verbose_Mode then
               Put (" (not active)");
            end if;

            if Is_Project_To_Install or Opt.Verbose_Mode then
               New_Line;
            end if;
         end if;

         --  If this is not an active project, just return now

         if not Is_Project_To_Install then
            return;
         end if;

         --  What should be copied

         Copy :=
           (Source     => For_Dev,
            Object     => For_Dev
                            and then Project.Mains = Nil_String
                            and then Project.Qualifier /= Library
                            and then Project.Qualifier /= Aggregate_Library
                            and then not Project.Library,
            Dependency => For_Dev and then Project.Mains = Nil_String,
            Library    => Project.Library
                            and then
                              ((For_Dev and then Is_Static (Project))
                                or else not Is_Static (Project)),
            Executable => Project.Mains /= Nil_String);

         --  Copy all files from the project

         Copy_Files;

         --  A project file is only needed in developer mode

         if For_Dev and then Install_Project then
            Create_Project (Project);
         end if;

         --  Add manifest into the main aggregate project manifest

         if Is_Open (Man) then
            if Is_Open (Agg_Manifest) then
               declare
                  Filename : constant String :=
                               Project_Dir & "manifests"
                               & DS & Simple_Name (Name (Man));
               begin
                  Close (Man);
                  Add_To_Manifest (Filename, Aggregate_Only => True);
               end;

            else
               Close (Man);
            end if;
         end if;

         --  Handle all projects recursively if needed

         if Recursive then
            declare
               L : Project_List := Project.Imported_Projects;
            begin
               while L /= null loop
                  Process (Tree, Node_Tree, L.Project);

                  L := L.Next;
               end loop;
            end;
         end if;
      end if;

      Free (Prefix_Dir);
      Free (Sources_Subdir);
      Free (Lib_Subdir);
      Free (Exec_Subdir);
      Free (Project_Subdir);
   end Process;

   -------------------
   -- Double_Buffer --
   -------------------

   procedure Double_Buffer is
      New_Buffer : constant GNAT.OS_Lib.String_Access :=
        new String (1 .. Buffer'Last * 2);
   begin
      New_Buffer (1 .. Buffer_Last) := Buffer (1 .. Buffer_Last);
      Free (Buffer);
      Buffer := New_Buffer;
   end Double_Buffer;

   ----------------
   -- Write_Char --
   ----------------

   procedure Write_Char (C : Character) is
   begin
      if Buffer_Last = Buffer'Last then
         Double_Buffer;
      end if;

      Buffer_Last := Buffer_Last + 1;
      Buffer (Buffer_Last) := C;
   end Write_Char;

   ---------------
   -- Write_Eol --
   ---------------

   procedure Write_Eol is
   begin
      Content.Append (New_Item => (Buffer (1 .. Buffer_Last)));
      Buffer_Last := 0;
   end Write_Eol;

   ---------------
   -- Write_Str --
   ---------------

   procedure Write_Str (S : String) is
   begin
      while Buffer_Last + S'Length > Buffer'Last loop
         Double_Buffer;
      end loop;

      Buffer (Buffer_Last + 1 .. Buffer_Last + S'Length) := S;
      Buffer_Last := Buffer_Last + S'Length;
   end Write_Str;

end Gprinstall.Install;
