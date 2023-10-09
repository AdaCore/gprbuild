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

with Ada.Calendar;
with Ada.Calendar.Time_Zones;                use Ada.Calendar.Time_Zones;
with Ada.Command_Line;                       use Ada.Command_Line;
with Ada.Containers.Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Directories;                        use Ada.Directories;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;
with Ada.Strings.Fixed;                      use Ada.Strings.Fixed;
with Ada.Strings.Maps;                       use Ada.Strings.Maps;
with Ada.Text_IO;               use Ada.Text_IO;
with Ada.Streams.Stream_IO;     use Ada.Streams;
with Ada.Exceptions;

with GNAT.Calendar.Time_IO;     use GNAT.Calendar.Time_IO;
with GNAT.Case_Util;            use GNAT.Case_Util;
with GNAT.HTable;
with GNAT.Regexp;               use GNAT.Regexp;
with GNAT.Table;
with GNAT.Calendar;             use GNAT.Calendar;
with GNAT.Directory_Operations; use GNAT.Directory_Operations;

with Interfaces.C.Strings;
with System;         use System;

with GPR.ALI;        use GPR.ALI;
with GPR.Com;
with GPR.Conf;
with GPR.Debug;
with GPR.Env;
with GPR.Err;
with GPR.Jobserver;
with GPR.Names;      use GPR.Names;
with GPR.Opt;        use GPR.Opt;
with GPR.Output;     use GPR.Output;
with GPR.Sdefault;
with GPR.Sinput;
with GPR.Snames;      use GPR.Snames;
with GPR.Version;     use GPR.Version;
with Gpr_Build_Util;  use Gpr_Build_Util;

package body GPR.Util is
   use Ada.Containers;

   Program_Name : String_Access := null;

   type File_Stamp_Record is record
      Known : Boolean         := False;
      TS    : Time_Stamp_Type := Empty_Time_Stamp;
   end record;
   Unknow_File_Stamp : constant File_Stamp_Record := (False, Empty_Time_Stamp);

   package File_Stamp_HTable is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => File_Stamp_Record,
      No_Element => Unknow_File_Stamp,
      Key        => Path_Name_Type,
      Hash       => GPR.Hash,
      Equal      => "=");
   --  A hash table to cache time stamps of files

   package Source_Info_Table is new GNAT.Table
     (Table_Component_Type => Source_Info_Iterator,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100);

   package Source_Info_Project_HTable is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => Natural,
      No_Element => 0,
      Key        => Name_Id,
      Hash       => GPR.Hash,
      Equal      => "=");

   procedure Free is new Ada.Unchecked_Deallocation
     (Text_File_Data, Text_File);

   package Processed_ALIs is new GNAT.HTable.Simple_HTable
     (Header_Num => GPR.Header_Num,
      Element    => Boolean,
      No_Element => False,
      Key        => File_Name_Type,
      Hash       => GPR.Hash,
      Equal      => "=");

   True_Checksum : constant File_Name_Type := File_Name_Type (First_Name_Id);
   --  Special constant to declare that checksum in Source record is calculated
   --  from source file content.

   function To_Path_String_Access
     (Path_Addr : Address;
      Path_Len  : Integer) return String_Access;
   --  Converts a C String to an Ada String.

   function Locate_Directory
     (Dir_Name : C_File_Name;
      Path     : C_File_Name) return String_Access;

   function C_String_Length (S : Address) return Integer;
   --  Returns the length of C (null-terminated) string at S, or 0 for
   --  Null_Address.

   function File_Stamp (Path : Path_Name_Type) return Time_Stamp_Type;
   --  Get the time stamp of Path. Take it from File_Stamp_HTable if it is
   --  already there, otherwise get it from OS and put into File_Stamp_HTable
   --  to be able to get it next time.

   ---------------------
   -- C_String_Length --
   ---------------------

   function C_String_Length (S : Address) return Integer is
      function strlen (A : Address) return size_t;
      pragma Import (Intrinsic, strlen, "strlen");
   begin
      if S = Null_Address then
         return 0;
      else
         return Integer (strlen (S));
      end if;
   end C_String_Length;

   ------------------------
   -- Calculate_Checksum --
   ------------------------

   function Calculate_Checksum (Source : Source_Id) return Boolean is
      Source_Index : Source_File_Index;
   begin
      if Source.Checksum_Src = True_Checksum then
         --  Checksum already calculated
         return True;
      end if;

      Source_Index :=
        Sinput.Load_File (Get_Name_String (Source.Path.Display_Name));

      if Source_Index /= No_Source_File then
         Err.Scanner.Initialize_Scanner (Source_Index, Err.Scanner.Ada);

         --  Scan the complete file to compute its
         --  checksum.

         loop
            Err.Scanner.Scan;
            exit when Token = Tok_EOF;
         end loop;

         Source.Checksum     := Scans.Checksum;
         Source.Checksum_Src := True_Checksum;

         --  If there were errors we can't Clear_Source_File_Table because the
         --  error messages refer to this table content.

         if Total_Errors_Detected = 0 then
            --  To avoid using too much memory, free the
            --  memory allocated.

            Sinput.Clear_Source_File_Table;
         end if;

         return True;
      end if;

      return False;
   end Calculate_Checksum;

   ------------------------
   -- Calculate_Checksum --
   ------------------------

   function Calculate_Checksum (File : Path_Name_Type) return Word is
      Source_Index : Source_File_Index;
      Checksum     : Word := 0;
   begin

      Source_Index :=
        Sinput.Load_File (Get_Name_String (File));

      if Source_Index /= No_Source_File then
         Err.Scanner.Initialize_Scanner (Source_Index, Err.Scanner.Ada);

         --  Scan the complete file to compute its
         --  checksum.

         loop
            Err.Scanner.Scan;
            exit when Token = Tok_EOF;
         end loop;

         Checksum := Scans.Checksum;

         --  If there were errors we can't Clear_Source_File_Table because the
         --  error messages refer to this table content.

         if Total_Errors_Detected = 0 then
            --  To avoid using too much memory, free the
            --  memory allocated.

            Sinput.Clear_Source_File_Table;
         end if;

         return Checksum;
      end if;

      return Checksum;
   end Calculate_Checksum;

   ----------------------------
   -- Clear_Time_Stamp_Cache --
   ----------------------------

   procedure Clear_Time_Stamp_Cache is
   begin
      File_Stamp_HTable.Reset;
   end Clear_Time_Stamp_Cache;

   ----------------
   -- File_Stamp --
   ----------------

   function File_Stamp (Path : Path_Name_Type) return Time_Stamp_Type is
   begin
      if Path = No_Path then
         return Empty_Time_Stamp;

      else
         declare
            FSR : File_Stamp_Record := File_Stamp_HTable.Get (Path);
         begin
            if FSR.Known then
               return FSR.TS;
            else
               declare
                  Result : constant Time_Stamp_Type := Osint.File_Stamp (Path);
               begin
                  FSR := (True, Result);
                  File_Stamp_HTable.Set (Path, FSR);
                  return Result;
               end;
            end if;
         end;
      end if;
   end File_Stamp;

   -----------------------
   -- Update_File_Stamp --
   -----------------------

   procedure Update_File_Stamp
     (Path  : Path_Name_Type;
      Stamp : Time_Stamp_Type)
   is
   begin
      if Path = No_Path then
         null;
      else
         File_Stamp_HTable.Set (Path, (True, Stamp));
      end if;
   end Update_File_Stamp;

   ----------------------
   -- Locate_Directory --
   ----------------------

   function Locate_Directory
     (Dir_Name : C_File_Name;
      Path     : C_File_Name) return String_Access
   is
      function Is_Dir (Name : Address) return Integer;
      pragma Import (C, Is_Dir, "__gnat_is_directory");

      function Locate_File_With_Predicate
        (File_Name, Path_Val, Predicate : Address) return Address;
      pragma Import
        (C, Locate_File_With_Predicate, "__gnat_locate_file_with_predicate");

      Result_Addr : Address;
      Result_Len  : Integer;
      Result      : String_Access := null;

   begin
      Result_Addr :=
        Locate_File_With_Predicate
          (Dir_Name, Path, Is_Dir'Address);
      Result_Len := C_String_Length (Result_Addr);

      if Result_Len /= 0 then
         Result := To_Path_String_Access (Result_Addr, Result_Len);
      end if;

      return Result;
   end Locate_Directory;

   function Locate_Directory
     (Dir_Name   : String;
      Path       : String) return String_Access
   is
      C_Dir_Name : String (1 .. Dir_Name'Length + 1);
      C_Path     : String (1 .. Path'Length + 1);
      Result     : String_Access;
   begin
      C_Dir_Name (1 .. Dir_Name'Length) := Dir_Name;
      C_Dir_Name (C_Dir_Name'Last)      := ASCII.NUL;

      C_Path     (1 .. Path'Length)     := Path;
      C_Path     (C_Path'Last)          := ASCII.NUL;

      Result := Locate_Directory (C_Dir_Name'Address, C_Path'Address);

      if Result /= null and then not Is_Absolute_Path (Result.all) then
         declare
            Absolute_Path : constant String := Normalize_Pathname (Result.all);
         begin
            Free (Result);
            Result := new String'(Absolute_Path);
         end;
      end if;

      return Result;
   end Locate_Directory;

   ---------------------------
   -- To_Path_String_Access --
   ---------------------------

   function To_Path_String_Access
     (Path_Addr : Address;
      Path_Len  : Integer) return String_Access
   is
      subtype Path_String is String (1 .. Path_Len);
      type    Path_String_Access is access Path_String;

      function Address_To_Access is new Ada.Unchecked_Conversion
        (Source => Address, Target => Path_String_Access);

      Path_Access : constant Path_String_Access :=
                      Address_To_Access (Path_Addr);

      Return_Val  : String_Access;

   begin
      Return_Val := new String (1 .. Path_Len);

      for J in 1 .. Path_Len loop
         Return_Val (J) := Path_Access (J);
      end loop;

      return Return_Val;
   end To_Path_String_Access;

   --------------
   -- Closures --
   --------------

   type Project_And_Tree is record
      Project : Project_Id;
      Tree    : Project_Tree_Ref;
   end record;

   function "<" (Left, Right : Project_And_Tree) return Boolean;

   package Projects_And_Trees_Sets is
     new Ada.Containers.Indefinite_Ordered_Sets
       (Element_Type => Project_And_Tree);

   type Main_Project_Tree is record
      Main    : Source_Id;
      Project : Project_Id;
      Tree    : Project_Tree_Ref;
   end record;

   function "<" (Left, Right : Main_Project_Tree) return Boolean;

   package MPT_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => Main_Project_Tree);

   package File_Name_Vectors is new Ada.Containers.Vectors
     (Positive, File_Name_Type);

   subtype File_Names is File_Name_Vectors.Vector;

   package Path_Sets renames String_Sets;

   ---------
   -- "<" --
   ---------

   function "<" (Left, Right : Project_And_Tree) return Boolean is
   begin
      return Left.Project.Name < Right.Project.Name;
   end "<";

   function "<" (Left, Right : Main_Project_Tree) return Boolean is
   begin
      if Left.Project.Name /= Right.Project.Name then
         return Left.Project.Name < Right.Project.Name;
      else
         return Left.Main.File < Right.Main.File;
      end if;
   end "<";

   -----------
   -- Close --
   -----------

   procedure Close (File : in out Text_File) is
      Len    : Integer;
      Status : Boolean;

   begin
      if File = null then
         GPR.Com.Fail ("Close attempted on an invalid Text_File");
      end if;

      if File.Out_File then
         if File.Buffer_Len > 0 then
            Len := Write (File.FD, File.Buffer'Address, File.Buffer_Len);

            if Len /= File.Buffer_Len then
               GPR.Com.Fail ("Unable to write to an out Text_File");
            end if;
         end if;

         Close (File.FD, Status);

         if not Status then
            GPR.Com.Fail ("Unable to close an out Text_File");
         end if;

      else

         --  Close in file, no need to test status, since this is a file that
         --  we read, and the file was read successfully before we closed it.

         Close (File.FD);
      end if;

      Free (File);
   end Close;

   ------------------------------
   -- Compilation_Phase_Failed --
   ------------------------------

   procedure Compilation_Phase_Failed
     (Project_Tree : Project_Tree_Ref;
      Exit_Code    : Exit_Code_Type := E_Fatal;
      No_Message   : Boolean        := False) is
   begin
      Fail_Program
        (Project_Tree, "*** compilation phase failed", Exit_Code,
         No_Message => No_Message);
   end Compilation_Phase_Failed;

   ------------
   -- Create --
   ------------

   procedure Create (File : out Text_File; Name : String) is
      FD        : File_Descriptor;
      File_Name : String (1 .. Name'Length + 1);

   begin
      File_Name (1 .. Name'Length) := Name;
      File_Name (File_Name'Last) := ASCII.NUL;
      FD := Create_File (Name => File_Name'Address,
                         Fmode => GNAT.OS_Lib.Text);

      if FD = Invalid_FD then
         File := null;

      else
         File := new Text_File_Data;
         File.FD := FD;
         File.Out_File := True;
         File.End_Of_File_Reached := True;
      end if;
   end Create;

   -------------------------------
   -- Common_Path_Prefix_Length --
   -------------------------------

   function Common_Path_Prefix_Length (A, B : String) return Integer is
      Slash : Integer := A'First;  --  At the last slash seen in A
      At_A  : Integer := A'First;
      At_B  : Integer := B'First;
   begin
      loop
         if At_A > A'Last then
            if At_B > B'Last or else B (At_B) = '/' then
               return A'Length;
            else
               return Slash - A'First;
            end if;
         elsif At_B > B'Last then
            if A (At_A) = '/' then  --  A cannot be shorter than B here
               return B'Length;
            else
               return Slash - A'First;
            end if;
         elsif A (At_A) /= B (At_B) then
            return Slash - A'First;
         elsif A (At_A) = '/' then
            Slash := At_A;
         end if;
         At_A := At_A + 1;
         At_B := At_B + 1;
      end loop;
   end Common_Path_Prefix_Length;

   -------------------
   -- Common_Prefix --
   -------------------

   function Common_Prefix (Pathname1, Pathname2 : String) return String is
      P1 : constant String := Normalize_Pathname (Pathname1);
      P2 : constant String := Normalize_Pathname (Pathname2);
      I1 : Positive := P1'First;
      I2 : Positive := P2'First;
   begin
      while I1 <= P1'Last
        and then I2 <= P2'Last
        and then P1 (I1) = P2 (I2)
      loop
         I1 := I1 + 1;
         I2 := I2 + 1;
      end loop;

      if I1 <= P1'Last or else I2 <= P2'Last then
         return P1 (P1'First .. I1 - 1);
      elsif I1 > P1'Last then
         return P2;
      else
         return P1;
      end if;
   end Common_Prefix;

   ---------------
   -- Duplicate --
   ---------------

   procedure Duplicate
     (This   : in out Name_List_Index;
      Shared : Shared_Project_Tree_Data_Access)
   is
      Old_Current : Name_List_Index;
      New_Current : Name_List_Index;

   begin
      if This /= No_Name_List then
         Old_Current := This;
         Name_List_Table.Increment_Last (Shared.Name_Lists);
         New_Current := Name_List_Table.Last (Shared.Name_Lists);
         This := New_Current;
         Shared.Name_Lists.Table (New_Current) :=
           (Shared.Name_Lists.Table (Old_Current).Name, No_Name_List);

         loop
            Old_Current := Shared.Name_Lists.Table (Old_Current).Next;
            exit when Old_Current = No_Name_List;
            Shared.Name_Lists.Table (New_Current).Next := New_Current + 1;
            Name_List_Table.Increment_Last (Shared.Name_Lists);
            New_Current := New_Current + 1;
            Shared.Name_Lists.Table (New_Current) :=
              (Shared.Name_Lists.Table (Old_Current).Name, No_Name_List);
         end loop;
      end if;
   end Duplicate;

   -----------------
   -- End_Of_File --
   -----------------

   function End_Of_File (File : Text_File) return Boolean is
   begin
      if File = null then
         GPR.Com.Fail ("End_Of_File attempted on an invalid Text_File");
      end if;

      return File.End_Of_File_Reached;
   end End_Of_File;

   -------------------
   -- Executable_Of --
   -------------------

   function Executable_Of
     (Project  : Project_Id;
      Shared   : Shared_Project_Tree_Data_Access;
      Main     : File_Name_Type;
      Index    : Int;
      Language : String := "";
      Include_Suffix : Boolean := True) return File_Name_Type
   is
      pragma Assert (Project /= No_Project);

      The_Packages : constant Package_Id := Project.Decl.Packages;

      Builder_Package : constant GPR.Package_Id :=
                          GPR.Util.Value_Of
                            (Name        => Name_Builder,
                             In_Packages => The_Packages,
                             Shared      => Shared);

      Executable : Variable_Value :=
                     GPR.Util.Value_Of
                       (Name                    => Name_Id (Main),
                        Index                   => Index,
                        Attribute_Or_Array_Name => Name_Executable,
                        In_Package              => Builder_Package,
                        Shared                  => Shared);

      Lang   : Language_Ptr;

      Spec_Suffix : Name_Id := No_Name;
      Body_Suffix : Name_Id := No_Name;

      Spec_Suffix_Length : Natural := 0;
      Body_Suffix_Length : Natural := 0;

      procedure Get_Suffixes
        (B_Suffix : File_Name_Type;
         S_Suffix : File_Name_Type);
      --  Get the non empty suffixes in variables Spec_Suffix and Body_Suffix

      function Add_Suffix (File : File_Name_Type) return File_Name_Type;
      --  Return the name of the executable, based on File, and adding the
      --  executable suffix if needed

      ------------------
      -- Get_Suffixes --
      ------------------

      procedure Get_Suffixes
        (B_Suffix : File_Name_Type;
         S_Suffix : File_Name_Type) is
      begin
         if B_Suffix /= No_File then
            Body_Suffix := Name_Id (B_Suffix);
            Body_Suffix_Length := Natural (Length_Of_Name (Body_Suffix));
         end if;

         if S_Suffix /= No_File then
            Spec_Suffix := Name_Id (S_Suffix);
            Spec_Suffix_Length := Natural (Length_Of_Name (Spec_Suffix));
         end if;
      end Get_Suffixes;

      ----------------
      -- Add_Suffix --
      ----------------

      function Add_Suffix (File : File_Name_Type) return File_Name_Type is
         Saved_EEOT : constant Name_Id := Executable_Extension_On_Target;
         Result     : File_Name_Type;
      begin
         if Include_Suffix then
            if Project.Config.Executable_Suffix /= No_Name then
               Executable_Extension_On_Target :=
                 Project.Config.Executable_Suffix;
            end if;

            Result :=  Executable_Name (File);
            Executable_Extension_On_Target := Saved_EEOT;
            return Result;
         end if;

         return File;
      end Add_Suffix;

   --  Start of processing for Executable_Of

   begin
      if Language /= "" then
         Lang := Get_Language_From_Name (Project, Language);
      end if;

      if Lang /= null then
         Get_Suffixes
           (B_Suffix => Lang.Config.Naming_Data.Body_Suffix,
            S_Suffix => Lang.Config.Naming_Data.Spec_Suffix);
      end if;

      if Builder_Package /= No_Package then
         if Executable = Nil_Variable_Value then
            Get_Name_String (Main);

            --  Try as index the name minus the implementation suffix or minus
            --  the specification suffix.

            declare
               Name : constant String (1 .. Name_Len) :=
                        Name_Buffer (1 .. Name_Len);
               Last : Positive := Name_Len;

               Truncated : Boolean := False;

            begin
               if Body_Suffix /= No_Name
                 and then Last > Natural (Length_Of_Name (Body_Suffix))
                 and then Name (Last - Body_Suffix_Length + 1 .. Last) =
                            Get_Name_String (Body_Suffix)
               then
                  Truncated := True;
                  Last := Last - Body_Suffix_Length;
               end if;

               if Spec_Suffix /= No_Name
                 and then not Truncated
                 and then Last > Spec_Suffix_Length
                 and then Name (Last - Spec_Suffix_Length + 1 .. Last) =
                            Get_Name_String (Spec_Suffix)
               then
                  Truncated := True;
                  Last := Last - Spec_Suffix_Length;
               end if;

               if Truncated then
                  Name_Len := Last;
                  Name_Buffer (1 .. Name_Len) := Name (1 .. Last);
                  Executable :=
                    GPR.Util.Value_Of
                      (Name                    => Name_Find,
                       Index                   => 0,
                       Attribute_Or_Array_Name => Name_Executable,
                       In_Package              => Builder_Package,
                       Shared                  => Shared);
               end if;
            end;
         end if;

         --  If we have found an Executable attribute, return its value,
         --  possibly suffixed by the executable suffix.

         if Executable /= Nil_Variable_Value
           and then Executable.Value /= No_Name
           and then Length_Of_Name (Executable.Value) /= 0
         then
            return Add_Suffix (File_Name_Type (Executable.Value));
         end if;
      end if;

      Get_Name_String (Main);

      --  If there is a body suffix or a spec suffix, remove this suffix,
      --  otherwise remove any suffix ('.' followed by other characters), if
      --  there is one.

      if Body_Suffix /= No_Name
         and then Name_Len > Body_Suffix_Length
         and then Name_Buffer (Name_Len - Body_Suffix_Length + 1 .. Name_Len) =
                    Get_Name_String (Body_Suffix)
      then
         --  Found the body termination, remove it

         Name_Len := Name_Len - Body_Suffix_Length;

      elsif Spec_Suffix /= No_Name
            and then Name_Len > Spec_Suffix_Length
            and then
              Name_Buffer (Name_Len - Spec_Suffix_Length + 1 .. Name_Len) =
                Get_Name_String (Spec_Suffix)
      then
         --  Found the spec termination, remove it

         Name_Len := Name_Len - Spec_Suffix_Length;

      else
         --  Remove any suffix, if there is one

         Get_Name_String (Strip_Suffix (Main));
      end if;

      return Add_Suffix (Name_Find);
   end Executable_Of;

   ----------------------------
   -- Executable_Prefix_Path --
   ----------------------------

   function Executable_Prefix_Path return String is
      Exec_Name : constant String := Command_Name;

      function Get_Install_Dir (S : String) return String;
      --  S is the executable name preceded by the absolute or relative path,
      --  e.g. "c:\usr\bin\gcc.exe". Returns the absolute directory where "bin"
      --  lies (in the example "C:\usr"). If the executable is not in a "bin"
      --  directory, return "".

      ---------------------
      -- Get_Install_Dir --
      ---------------------

      function Get_Install_Dir (S : String) return String is
         Exec      : String  := Normalize_Pathname (S, Resolve_Links => True);
         Path_Last : Integer := 0;

      begin
         for J in reverse Exec'Range loop
            if Is_Directory_Separator (Exec (J)) then
               Path_Last := J - 1;
               exit;
            end if;
         end loop;

         if Path_Last >= Exec'First + 2 then
            To_Lower (Exec (Path_Last - 2 .. Path_Last));
         end if;

         if Path_Last < Exec'First + 2
           or else Exec (Path_Last - 2 .. Path_Last) /= "bin"
           or else (Path_Last - 3 >= Exec'First
                    and then not Is_Directory_Separator (Exec (Path_Last - 3)))
         then
            return "";
         end if;

         return (Exec (Exec'First .. Path_Last - 4)) & Directory_Separator;
      end Get_Install_Dir;

   --  Beginning of Executable_Prefix_Path

   begin
      --  First determine if a path prefix was placed in front of the
      --  executable name.

      for J in reverse Exec_Name'Range loop
         if Is_Directory_Separator (Exec_Name (J)) then
            return Get_Install_Dir (Exec_Name);
         end if;
      end loop;

      --  If we get here, the user has typed the executable name with no
      --  directory prefix.

      declare
         Path : String_Access := Locate_Exec_On_Path (Exec_Name);
      begin
         if Path = null then
            return "";
         else
            declare
               Dir : constant String := Get_Install_Dir (Path.all);
            begin
               Free (Path);
               return Dir;
            end;
         end if;
      end;
   end Executable_Prefix_Path;

   ------------
   -- Expect --
   ------------

   procedure Expect (The_Token : Token_Type; Token_Image : String) is
   begin
      if Token /= The_Token then

         --  ??? Should pass user flags here instead

         Err.Error_Msg
           (Gprbuild_Flags, Token_Image & " expected", Token_Ptr,
            One_Line => True);
      end if;
   end Expect;

   ------------------
   -- Fail_Program --
   ------------------

   procedure Fail_Program
     (Project_Tree   : Project_Tree_Ref;
      Message        : String;
      Exit_Code      : Exit_Code_Type := E_Fatal;
      Flush_Messages : Boolean        := True;
      No_Message     : Boolean        := False;
      Command        : String         := "") is
   begin
      if Flush_Messages and not No_Message then
         if Total_Errors_Detected /= 0 or else Warnings_Detected /= 0 then
            Err.Finalize;
         end if;
      end if;

      GPR.Jobserver.Unregister_All_Token_Id;

      Finish_Program
        (Project_Tree,
         Exit_Code  => Exit_Code,
         Message    => Message,
         No_Message => No_Message,
         Command => Command);
   end Fail_Program;

   --------------------
   -- Finish_Program --
   --------------------

   procedure Finish_Program
     (Project_Tree : Project_Tree_Ref;
      Exit_Code    : Exit_Code_Type := E_Success;
      Message      : String         := "";
      No_Message   : Boolean        := False;
      Command      : String         := "") is
   begin
      if not Opt.Keep_Temporary_Files then
         Delete_All_Temp_Files
           (if Project_Tree = null then null else Project_Tree.Shared);
      end if;

      if Message'Length > 0 and then not No_Message then
         if Exit_Code not in E_Success | E_Subtool then
            Set_Standard_Error;
         end if;
         Write_Program_Name;
         Write_Line (Message);
         if Command /= "" then
            Write_Program_Name;
            Write_Line (Command);
         end if;
      end if;

      Exit_Program (Exit_Code);
   end Finish_Program;

   ---------------------------
   -- For_Interface_Sources --
   ---------------------------

   procedure For_Interface_Sources
     (Tree    : Project_Tree_Ref;
      Project : Project_Id)
   is
      package Dep_Names renames String_Sets;

      function Less_Than (Left, Right : Source_Id) return Boolean is
        (Get_Name_String (Left.File) < Get_Name_String (Right.File));

      package Interface_Source_Ids is
        new Ada.Containers.Ordered_Sets
          (Element_Type => Source_Id,
           "<"          => Less_Than,
           "="          => "=");

      function Load_ALI (Filename : String) return ALI_Id;
      --  Load an ALI file and return its id

      --------------
      -- Load_ALI --
      --------------

      function Load_ALI (Filename : String) return ALI_Id is
         Result   : ALI_Id := No_ALI_Id;
         Text     : Text_Buffer_Ptr;
         Lib_File : File_Name_Type;

      begin
         if Ada.Directories.Exists (Filename) then
            Lib_File := Get_File_Name_Id (Filename);
            Text := Osint.Read_Library_Info (Lib_File);
            Result :=
              ALI.Scan_ALI
                (Lib_File,
                 Text,
                 Ignore_ED  => False,
                 Err        => True,
                 Read_Lines => "UD");
            Free (Text);
         end if;

         return Result;
      end Load_ALI;

      --  Local declarations

      Iter : Source_Iterator;
      Sid  : Source_Id;
      ALI  : ALI_Id;

      First_Unit  : Unit_Id;
      Second_Unit : Unit_Id;
      Body_Needed : Boolean;
      Deps        : Dep_Names.Set;

      Sids : Interface_Source_Ids.Set;

   --  Start of processing for For_Interface_Sources

   begin
      if Project.Qualifier = Aggregate_Library then
         Iter := For_Each_Source (Tree);
      else
         Iter := For_Each_Source (Tree, Project);
      end if;

      --  First look at each spec, check if the body is needed

      loop
         Sid := Element (Iter);
         exit when Sid = No_Source;

         --  Skip sources that are removed/excluded and sources not part of
         --  the interface for standalone libraries.

         if Sid.Kind = Spec
           and then (not Sid.Project.Externally_Built
                      or else Sid.Project = Project)
           and then not Sid.Locally_Removed
           and then (Project.Standalone_Library = No
                      or else Sid.Declared_In_Interfaces)

           --  Handle case of non-compilable languages

           and then Sid.Dep_Name /= No_File
         then
            Sids.Include (Sid);

            --  Check ALI for dependencies on body and sep

            ALI :=
              Load_ALI
                (Get_Name_String (Get_Object_Directory (Sid.Project, True))
                 & Get_Name_String (Sid.Dep_Name));

            if ALI /= No_ALI_Id then
               First_Unit := ALIs.Table (ALI).First_Unit;
               Second_Unit := No_Unit_Id;
               Body_Needed := True;

               --  If there is both a spec and a body, check if both needed

               if Units.Table (First_Unit).Utype = Is_Body then
                  Second_Unit := ALIs.Table (ALI).Last_Unit;

                  --  If the body is not needed, then reset First_Unit

                  if not Units.Table (Second_Unit).Body_Needed_For_SAL then
                     Body_Needed := False;
                  end if;

               elsif Units.Table (First_Unit).Utype = Is_Spec_Only then
                  Body_Needed := False;
               end if;

               --  Handle all the separates, if any

               if Body_Needed then
                  if Other_Part (Sid) /= null then
                     Deps.Include (Get_Name_String (Other_Part (Sid).File));
                  end if;

                  for Dep in ALIs.Table (ALI).First_Sdep ..
                    ALIs.Table (ALI).Last_Sdep
                  loop
                     if Sdep.Table (Dep).Subunit_Name /= No_Name then
                        Deps.Include
                          (Get_Name_String (Sdep.Table (Dep).Sfile));
                     end if;
                  end loop;
               end if;
            end if;
         end if;

         Next (Iter);
      end loop;

      --  Now handle the bodies and separates if needed

      if Deps.Length /= 0 then
         if Project.Qualifier = Aggregate_Library then
            Iter := For_Each_Source (Tree);
         else
            Iter := For_Each_Source (Tree, Project);
         end if;

         loop
            Sid := Element (Iter);
            exit when Sid = No_Source;

            if Sid.Kind /= Spec
              and then Deps.Contains (Get_Name_String (Sid.File))
            then
               Sids.Include (Sid);
            end if;

            Next (Iter);
         end loop;
      end if;

      --  Call Action for all the sources, in order

      for E of Sids loop
         Action (E);
      end loop;
   end For_Interface_Sources;

   ------------------
   -- Get_Closures --
   ------------------

   procedure Get_Closures
     (Project                  : Project_Id;
      In_Tree                  : Project_Tree_Ref;
      Mains                    : String_Vectors.Vector;
      All_Projects             : Boolean := True;
      Include_Externally_Built : Boolean := False;
      Status                   : out Status_Type;
      Result                   : out String_Vectors.Vector)
   is
      Closures             : Path_Sets.Set;
      Projects_And_Trees   : Projects_And_Trees_Sets.Set;
      Mains_Projects_Trees : MPT_Sets.Set;

      The_File_Names : File_Names := File_Name_Vectors.Empty_Vector;

      procedure Add_To_Projects (Proj : Project_Id; Tree : Project_Tree_Ref);
      --  Add project Proc with its Tree to the list of projects

      procedure Add_To_Mains
        (Main    : Source_Id;
         Project : Project_Id;
         Tree    : Project_Tree_Ref);
      --  Add main Main with its Project and Tree to the list of mains

      procedure Add_To_Closures (Source : Source_Id; Added : out Boolean);
      --  Add Source to the list of closures. Added is True when Source is
      --  effectively added. If Source was already in the list of closures, it
      --  is not added again and Added is False.

      procedure Look_For_Mains;
      --  Look for mains in the project trees. Status is Success only if
      --  all mains have been found.

      procedure Get_Aggregated (Proj : Project_Id);
      --  Get the non aggregated projects from Aggregate project Proj

      procedure Cleanup;
      --  Deallocate the local lists

      procedure Initialize_Sources;
      --  Initialize all the source records in all the trees

      procedure Process
        (Source  : Source_Id;
         Project : Project_Id;
         Tree    : Project_Tree_Ref);
      --  Get the sources in the closure of Main and add them to the list of
      --  closures.

      ---------------------
      -- Add_To_Closures --
      ---------------------

      procedure Add_To_Closures (Source : Source_Id; Added : out Boolean) is
         Position : Path_Sets.Cursor;
      begin
         Added := False;

         if Source /= No_Source then
            Path_Sets.Insert
              (Container => Closures,
               New_Item  => Get_Name_String (Source.Path.Display_Name),
               Position  => Position,
               Inserted  => Added);
         end if;
      end Add_To_Closures;

      ------------------
      -- Add_To_Mains --
      ------------------

      procedure Add_To_Mains
        (Main    : Source_Id;
         Project : Project_Id;
         Tree    : Project_Tree_Ref)
      is
         Position : MPT_Sets.Cursor;
         Inserted : Boolean;

      begin
         Mains_Projects_Trees.Insert
           (New_Item => (Main, Project, Tree),
            Position => Position,
            Inserted => Inserted);
      end Add_To_Mains;

      ---------------------
      -- Add_To_Projects --
      ---------------------

      procedure Add_To_Projects (Proj : Project_Id; Tree : Project_Tree_Ref) is
      begin
         Projects_And_Trees.Insert ((Proj, Tree));
      end Add_To_Projects;

      -------------
      -- Cleanup --
      -------------

      procedure Cleanup is
      begin
         Closures.Clear;
         Projects_And_Trees.Clear;
         Mains_Projects_Trees.Clear;
         The_File_Names.Clear;
      end Cleanup;

      --------------------
      -- Get_Aggregated --
      --------------------

      procedure Get_Aggregated (Proj : Project_Id) is
         List : Aggregated_Project_List := null;
         Prj : Project_Id;
      begin
         if Proj.Qualifier = Aggregate then
            List := Proj.Aggregated_Projects;
         end if;

         while List /= null loop
            Prj := List.Project;

            case Prj.Qualifier is
               when Library | Configuration |
                    Abstract_Project | Aggregate_Library =>
                  null;

               when Unspecified | Standard =>
                  if not Prj.Library and then not Prj.Externally_Built then
                     Add_To_Projects (Prj, List.Tree);
                  end if;

               when Aggregate =>
                  Get_Aggregated (Prj);
            end case;

            List := List.Next;
         end loop;
      end Get_Aggregated;

      ------------------------
      -- Initialize_Sources --
      ------------------------

      procedure Initialize_Sources is
         Last     : constant Projects_And_Trees_Sets.Cursor :=
                      Projects_And_Trees_Sets.Last (Projects_And_Trees);
         Position : Projects_And_Trees_Sets.Cursor :=
                      Projects_And_Trees_Sets.First (Projects_And_Trees);
         Iter   : Source_Iterator;
         Src    : Source_Id;
         The_Project_And_Tree : Project_And_Tree;

         use type Projects_And_Trees_Sets.Cursor;

      begin
         loop
            The_Project_And_Tree := Projects_And_Trees_Sets.Element (Position);

            --  Initialize all the Ada sources of the project tree, even if
            --  All_Projects is False.

            Iter := For_Each_Source
              (In_Tree           => The_Project_And_Tree.Tree,
               Language          => Name_Ada,
               Encapsulated_Libs => True,
               Locally_Removed   => False);

            loop
               Src := Element (Iter);
               exit when Src = No_Source;
               Initialize_Source_Record (Src);
               Next (Iter);
            end loop;

            exit when Position = Last;
            Projects_And_Trees_Sets.Next (Position);
         end loop;
      end Initialize_Sources;

      --------------------
      -- Look_For_Mains --
      --------------------

      procedure Look_For_Mains is
      begin
         for FName of The_File_Names loop
            declare
               Saved_Mains_Length : constant Ada.Containers.Count_Type :=
                 Mains_Projects_Trees.Length;
               Position : Projects_And_Trees_Sets.Cursor :=
                 Projects_And_Trees_Sets.First (Projects_And_Trees);
               Last : constant Projects_And_Trees_Sets.Cursor :=
                 Projects_And_Trees_Sets.Last (Projects_And_Trees);

               use type Projects_And_Trees_Sets.Cursor;

               The_PT : Project_And_Tree;

            begin
               loop
                  The_PT := Projects_And_Trees_Sets.Element (Position);

                  --  find the main in the project tree

                  declare
                     Source : Source_Id;

                     The_Tree    : constant Project_Tree_Ref := The_PT.Tree;
                     The_Project : constant Project_Id       := The_PT.Project;

                     Sources : constant Source_Ids :=
                       Find_All_Sources
                         (In_Tree          => The_Tree,
                          Project          => The_Project,
                          In_Imported_Only => False,
                          In_Extended_Only => False,
                          Base_Name        => FName);

                  begin
                     for L in Sources'Range loop
                        Source := Sources (L);

                        if Source.Language.Config.Kind /= Unit_Based then
                           Status := Invalid_Main;
                           return;

                        elsif Source.Project = The_Project then
                           Add_To_Mains
                             (Main    => Source,
                              Project => The_Project,
                              Tree    => The_Tree);

                        elsif All_Projects then
                           if not Source.Project.Externally_Built
                             or else Include_Externally_Built
                           then
                              Add_To_Mains
                                (Main    => Source,
                                 Project => The_Project,
                                 Tree    => The_Tree);
                           end if;
                        end if;
                     end loop;
                  end;

                  exit when Position = Last;
                  Projects_And_Trees_Sets.Next (Position);
               end loop;

               if Mains_Projects_Trees.Length = Saved_Mains_Length then
                  Status := Invalid_Main;
                  return;
               end if;
            end;
         end loop;
      end Look_For_Mains;

      -------------
      -- Process --
      -------------

      procedure Process
        (Source  : Source_Id;
         Project : Project_Id;
         Tree    : Project_Tree_Ref)
      is
         --  Add Source to the closures, if not there yet, and continue with
         --  the sources it imports.
         Text       : Text_Buffer_Ptr;
         Idread     : ALI_Id;
         First_Unit : Unit_Id;
         Last_Unit  : Unit_Id;
         Unit_Data  : Unit_Record;
         The_ALI    : File_Name_Type;
         Added      : Boolean;

         procedure Find_Unit (Uname : String);
         --  Find the sources for this unit name

         ---------------
         -- Find_Unit --
         ---------------

         procedure Find_Unit (Uname : String) is
            Iter : Source_Iterator;
            Src  : Source_Id;

            Unit_Name : constant String :=
              Uname (Uname'First .. Uname'Last - 2);

            Proj : Project_Id;
         begin
            if All_Projects then
               Proj := No_Project;
            else
               Proj := Project;
            end if;

            Iter := For_Each_Source
              (In_Tree           => Tree,
               Project           => Proj,
               Language          => Name_Ada,
               Encapsulated_Libs => True,
               Locally_Removed   => False);

            loop
               Src := Element (Iter);
               exit when Src = No_Source;

               if Src.Unit /= No_Unit_Index
                 and then Get_Name_String (Src.Unit.Name) = Unit_Name
               then
                  Process (Src, Src.Project, Tree);
               end if;

               Next (Iter);
            end loop;
         end Find_Unit;

      begin
         --  Nothing to do if the project is externally built and
         --  Include_Externally_Built is False.

         if Project.Externally_Built and then not Include_Externally_Built then
            return;
         end if;

         Add_To_Closures (Source, Added);

         if not Added then
            return;
         end if;

         The_ALI := File_Name_Type (Source.Dep_Path);

         if not Processed_ALIs.Get (The_ALI) then
            Processed_ALIs.Set (The_ALI, True);

            Text := Read_Library_Info (The_ALI);

            if Text = null then
               Status := Incomplete_Closure;

            else
               Idread :=
                 Scan_ALI
                   (F          => The_ALI,
                    T          => Text,
                    Ignore_ED  => False,
                    Err        => True,
                    Read_Lines => "WD");
               Free (Text);

               if Idread = No_ALI_Id then
                  Status := Incomplete_Closure;

               else
                  First_Unit := ALI.ALIs.Table (Idread).First_Unit;
                  Last_Unit  := ALI.ALIs.Table (Idread).Last_Unit;

                  for Unit in First_Unit .. Last_Unit loop
                     Unit_Data := ALI.Units.Table (Unit);

                     if Unit = First_Unit then
                        declare
                           Uname : constant String :=
                             Get_Name_String (Unit_Data.Uname);
                        begin
                           Find_Unit (Uname);

                           --  For a body, check if there are subunits

                           if Uname (Uname'Last - 1 .. Uname'Last) = "%b" then
                              for D in ALI.ALIs.Table (Idread).First_Sdep ..
                                ALI.ALIs.Table (Idread).Last_Sdep
                              loop
                                 declare
                                    Sdep : constant Sdep_Record :=
                                      ALI.Sdep.Table (D);
                                 begin
                                    if Sdep.Subunit_Name /= No_Name then
                                       declare
                                          Subunit_Name : constant String :=
                                            Get_Name_String
                                              (Sdep.Subunit_Name);
                                          File_Name :
                                            constant File_Name_Type :=
                                               Sdep.Sfile;
                                          Iter : Source_Iterator;
                                          Src : Source_Id;
                                       begin
                                          if
                                            Subunit_Name'Length >=
                                              Uname'Length - 2
                                              and then Subunit_Name
                                               (Subunit_Name'First ..
                                                Subunit_Name'First +
                                                Uname'Length - 3) =
                                             Uname (Uname'First ..
                                                    Uname'Last - 2)
                                              and then Subunit_Name
                                               (Subunit_Name'First +
                                                Uname'Length - 2) = '.'
                                          then
                                             --  Add the subunit to the closure
                                             --  First, find the source
                                             Iter := For_Each_Source
                                               (In_Tree           => Tree,
                                                Project           => Project,
                                                Language          => Name_Ada,
                                                Encapsulated_Libs => True,
                                                Locally_Removed   => False);

                                             loop
                                                Src := Element (Iter);
                                                exit when Src = No_Source;
                                                exit when Src.File = File_Name;
                                                Next (Iter);
                                             end loop;

                                             --  If the source has been found,
                                             --  add it to the closure.
                                             if Src /= No_Source then
                                                Add_To_Closures (Src, Added);
                                             end if;
                                          end if;
                                       end;
                                    end if;
                                 end;
                              end loop;
                           end if;
                        end;
                     end if;

                     for W in Unit_Data.First_With ..
                       Unit_Data.Last_With
                     loop
                        Find_Unit (Get_Name_String (Withs.Table (W).Uname));
                     end loop;
                  end loop;
               end if;
            end if;
         end if;
      end Process;

   begin
      Status := Success;
      Result := String_Vectors.Empty_Vector;

      --  Fail immediately if there are no Mains

      if Mains.Is_Empty then
         Status := No_Main;
         Cleanup;
         return;

      else
         The_File_Names.Clear;

         for Src of Mains loop
            if Src'Length = 0 then
               Status := No_Main;
               Cleanup;
               return;

            else
               Name_Len := Src'Length;
               Name_Buffer (1 .. Name_Len) := Src;
               The_File_Names.Append (Name_Find);
            end if;
         end loop;
      end if;

      --  First check if there are any valid project or projects

      if Project = No_Project or else In_Tree = No_Project_Tree then
         Err.Error_Msg
           (Gprbuild_Flags, "Project not found", Token_Ptr,
            Project => Project);
         Status := Invalid_Project;
         Cleanup;
         return;
      end if;

      if Project.Externally_Built then
         Err.Error_Msg
           (Gprbuild_Flags, "No closures for external projects", Token_Ptr,
            Project => Project);
         Status := Invalid_Project;
         Cleanup;
         return;
      end if;

      case Project.Qualifier is
         when Configuration | Abstract_Project =>
            Err.Error_Msg
              (Gprbuild_Flags, "No closures for abstract or configuration",
               Token_Ptr, Project => Project);
            Status := Invalid_Project;
            Cleanup;
            return;

         when Standard | Library | Unspecified =>
            Add_To_Projects (Project, In_Tree);

         when Aggregate | Aggregate_Library =>
            if not All_Projects then
               Err.Error_Msg
                 (Gprbuild_Flags, "Aggregate closure must be recursive",
                  Token_Ptr, Project => Project);
               Status := Invalid_Project;
               Cleanup;
               return;
            end if;

            Get_Aggregated (Project);
      end case;

      if Projects_And_Trees.Length = 0 then
         Err.Error_Msg
           (Gprbuild_Flags, "No projects to closure", Token_Ptr,
            Project => Project);
         Status := Invalid_Project;
         Cleanup;
         return;
      end if;

      --  Initialize the source records for all sources in the project trees

      Initialize_Sources;

      --  Now that we have the valid project(s), look for the mains

      Look_For_Mains;

      if Status /= Success then
         Cleanup;
         return;
      end if;

      --  Now that we have the main sources, get their closures

      Processed_ALIs.Reset;

      declare
         Position : MPT_Sets.Cursor := MPT_Sets.First (Mains_Projects_Trees);
         Last     : constant MPT_Sets.Cursor :=
           MPT_Sets.Last (Mains_Projects_Trees);
         The_MPT : Main_Project_Tree;

         use type MPT_Sets.Cursor;

      begin
         loop
            The_MPT := MPT_Sets.Element (Position);
            Process (The_MPT.Main, The_MPT.Project, The_MPT.Tree);
            exit when Position = Last;
            MPT_Sets.Next (Position);
         end loop;
      end;

      for Closure of Closures loop
         Result.Append (Closure);
      end loop;

      Cleanup;

   exception
      when Ex : others =>
         Debug_Output (Ada.Exceptions.Exception_Information (Ex));
         Result.Clear;
         Status := Unknown_Error;
   end Get_Closures;

   --------------
   -- Get_Line --
   --------------

   procedure Get_Line
     (File : Text_File;
      Line : out String;
      Last : out Natural)
   is
      C : Character;

      procedure Advance;

      -------------
      -- Advance --
      -------------

      procedure Advance is
      begin
         if File.Cursor = File.Buffer_Len then
            File.Buffer_Len :=
              Read
               (FD => File.FD,
                A  => File.Buffer'Address,
                N  => File.Buffer'Length);

            if File.Buffer_Len = 0 then
               File.End_Of_File_Reached := True;
               return;
            else
               File.Cursor := 1;
            end if;

         else
            File.Cursor := File.Cursor + 1;
         end if;
      end Advance;

   --  Start of processing for Get_Line

   begin
      if File = null then
         GPR.Com.Fail ("Get_Line attempted on an invalid Text_File");

      elsif File.Out_File then
         GPR.Com.Fail ("Get_Line attempted on an out file");
      end if;

      Last := Line'First - 1;

      if not File.End_Of_File_Reached then
         loop
            C := File.Buffer (File.Cursor);
            exit when C = ASCII.CR or else C = ASCII.LF;
            Last := Last + 1;
            Line (Last) := C;
            Advance;

            if File.End_Of_File_Reached then
               return;
            end if;

            exit when Last = Line'Last;
         end loop;

         if C = ASCII.CR or else C = ASCII.LF then
            Advance;

            if File.End_Of_File_Reached then
               return;
            end if;
         end if;

         if C = ASCII.CR
           and then File.Buffer (File.Cursor) = ASCII.LF
         then
            Advance;
         end if;
      end if;
   end Get_Line;

   --------------
   -- Get_Line --
   --------------

   function Get_Line
     (File : Text_File; Max_Length : Positive := 4096) return String
   is
      Result : String (1 .. Max_Length);
      Last   : Natural;
   begin
      Get_Line (File, Result, Last);
      return Result (1 .. Last);
   end Get_Line;

   ------------------
   -- Get_Switches --
   ------------------

   procedure Get_Switches
     (Source       : GPR.Source_Id;
      Pkg_Name     : Name_Id;
      Project_Tree : Project_Tree_Ref;
      Value        : out Variable_Value;
      Is_Default   : out Boolean) is
   begin
      Get_Switches
        (Source_File  => Source.File,
         Source_Lang  => Source.Language.Name,
         Source_Prj   => Source.Project,
         Pkg_Name     => Pkg_Name,
         Project_Tree => Project_Tree,
         Value        => Value,
         Is_Default   => Is_Default);
   end Get_Switches;

   procedure Get_Switches
     (Source_File         : File_Name_Type;
      Source_Lang         : Name_Id;
      Source_Prj          : Project_Id;
      Pkg_Name            : Name_Id;
      Project_Tree        : Project_Tree_Ref;
      Value               : out Variable_Value;
      Is_Default          : out Boolean;
      Test_Without_Suffix : Boolean := False;
      Check_ALI_Suffix    : Boolean := False)
   is
      Project : constant Project_Id :=
                  Ultimate_Extending_Project_Of (Source_Prj);
      Pkg     : constant Package_Id :=
                  GPR.Util.Value_Of
                    (Name        => Pkg_Name,
                     In_Packages => Project.Decl.Packages,
                     Shared      => Project_Tree.Shared);
      Lang : Language_Ptr;

   begin
      Is_Default := False;

      if Source_File /= No_File then
         Value := GPR.Util.Value_Of
           (Name                    => Name_Id (Source_File),
            Attribute_Or_Array_Name => Name_Switches,
            In_Package              => Pkg,
            Shared                  => Project_Tree.Shared,
            Allow_Wildcards         => True);
      end if;

      if Value = Nil_Variable_Value and then Test_Without_Suffix then
         Lang :=
           Get_Language_From_Name (Project, Get_Name_String (Source_Lang));

         if Lang /= null then
            declare
               Naming      : Lang_Naming_Data renames Lang.Config.Naming_Data;
               SF_Name     : constant String := Get_Name_String (Source_File);
               Last        : Positive := SF_Name'Length;
               Name        : String (1 .. Last + 3);
               Spec_Suffix : String   := Get_Name_String (Naming.Spec_Suffix);
               Body_Suffix : String   := Get_Name_String (Naming.Body_Suffix);
               Truncated   : Boolean  := False;

            begin
               Canonical_Case_File_Name (Spec_Suffix);
               Canonical_Case_File_Name (Body_Suffix);
               Name (1 .. Last) := SF_Name;

               if Last > Body_Suffix'Length
                 and then
                   Name (Last - Body_Suffix'Length + 1 .. Last) = Body_Suffix
               then
                  Truncated := True;
                  Last := Last - Body_Suffix'Length;
               end if;

               if not Truncated
                 and then Last > Spec_Suffix'Length
                 and then
                   Name (Last - Spec_Suffix'Length + 1 .. Last) = Spec_Suffix
               then
                  Truncated := True;
                  Last := Last - Spec_Suffix'Length;
               end if;

               if Truncated then
                  Value := GPR.Util.Value_Of
                    (Name                    => Get_Name_Id (Name (1 .. Last)),
                     Attribute_Or_Array_Name => Name_Switches,
                     In_Package              => Pkg,
                     Shared                  => Project_Tree.Shared,
                     Allow_Wildcards         => True);
               end if;

               if Value = Nil_Variable_Value and then Check_ALI_Suffix then
                  Last := SF_Name'Length;
                  while Name (Last) /= '.' loop
                     Last := Last - 1;
                  end loop;

                  Value := GPR.Util.Value_Of
                    (Get_Name_Id (Name (1 .. Last) & "ali"),
                     Attribute_Or_Array_Name => Name_Switches,
                     In_Package              => Pkg,
                     Shared                  => Project_Tree.Shared,
                     Allow_Wildcards         => True);
               end if;
            end;
         end if;
      end if;

      if Value = Nil_Variable_Value then
         Is_Default := True;
         Value :=
           GPR.Util.Value_Of
             (Name                    => Source_Lang,
              Attribute_Or_Array_Name => Name_Switches,
              In_Package              => Pkg,
              Shared                  => Project_Tree.Shared,
              Force_Lower_Case_Index  => True);
      end if;

      if Value = Nil_Variable_Value then
         Value :=
           GPR.Util.Value_Of
             (Name                    => All_Other_Names,
              Attribute_Or_Array_Name => Name_Switches,
              In_Package              => Pkg,
              Shared                  => Project_Tree.Shared,
              Force_Lower_Case_Index  => True);
      end if;

      if Value = Nil_Variable_Value then
         Value :=
           GPR.Util.Value_Of
             (Name                    => Source_Lang,
              Attribute_Or_Array_Name => Name_Default_Switches,
              In_Package              => Pkg,
              Shared                  => Project_Tree.Shared);
      end if;
   end Get_Switches;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize
     (Iter        : out Source_Info_Iterator;
      For_Project : Name_Id)
   is
      Ind : constant Natural := Source_Info_Project_HTable.Get (For_Project);
   begin
      if Ind = 0 then
         Iter := (No_Source_Info, 0);
      else
         Iter := Source_Info_Table.Table (Ind);
      end if;
   end Initialize;

   ------------------------------
   -- Initialize_Source_Record --
   ------------------------------

   procedure Initialize_Source_Record
     (Source : GPR.Source_Id;
      Always : Boolean := False)
   is

      Main_Source_File : File_Name_Type := Source.File;

      procedure Set_Object_Project
        (Obj_Dir  : String;
         Obj_Proj : Project_Id;
         Obj_Path : Path_Name_Type;
         Stamp    : Time_Stamp_Type);
      --  Update information about object file, switches file,...

      ------------------------
      -- Set_Object_Project --
      ------------------------

      procedure Set_Object_Project
        (Obj_Dir  : String;
         Obj_Proj : Project_Id;
         Obj_Path : Path_Name_Type;
         Stamp    : Time_Stamp_Type) is
      begin
         Source.Object_Project := Obj_Proj;
         Source.Object_Path    := Obj_Path;
         Source.Object_TS      := Stamp;

         if Source.Language.Config.Dependency_Kind /= None then
            declare
               Dep_Path : constant String :=
                            Normalize_Pathname
                              (Get_Name_String (Source.Dep_Name),
                               Resolve_Links => Opt.Follow_Links_For_Files,
                               Directory     => Obj_Dir);
            begin
               if not Gprls_Mode
                 or else Obj_Proj.Extends = No_Project
                 or else Is_Regular_File (Dep_Path)
               then
                  Source.Dep_Path := Create_Name (Dep_Path);
                  Source.Dep_TS   := Unknown_Attributes;
               end if;
            end;
         end if;

         --  Get the path of the switches file, even if Opt.Check_Switches is
         --  not set, as switch -s may be in the Builder switches that have not
         --  been scanned yet.

         declare
            Switches_Path : constant String :=
                              Normalize_Pathname
                                (Get_Name_String (Source.Switches),
                                 Resolve_Links => Opt.Follow_Links_For_Files,
                                 Directory     => Obj_Dir);
         begin
            Source.Switches_Path := Create_Name (Switches_Path);

            if Stamp /= Empty_Time_Stamp then
               Source.Switches_TS := File_Stamp (Source.Switches_Path);
            end if;
         end;
      end Set_Object_Project;

      Obj_Proj : Project_Id;

   begin
      --  Nothing to do if source record has already been fully initialized

      if Source.Initialized and not Always then
         return;
      end if;

      --  Systematically recompute the time stamp

      Source.Source_TS := File_Stamp (Source.Path.Display_Name);

      --  Parse the source file to check whether we have a subunit

      if Source.Language.Config.Kind = Unit_Based
        and then Source.Kind = Impl
        and then Is_Subunit (Source)
      then
         Source.Kind := Sep;
      end if;

      if Source.Language.Config.Object_Generated
        and then Is_Compilable (Source)
      then
         --  First, get the correct object file name and dependency file

         if Source.Unit /= No_Unit_Index
           and then Source.Kind = Spec
           and then Other_Part (Source) /= No_Source
         then
            Main_Source_File := Other_Part (Source).File;
            Source.Object :=
              Object_Name
                (Main_Source_File, Source.Language.Config.Object_File_Suffix);
            Source.Dep_Name :=
              Dependency_Name
                (Source.Object, Source.Language.Config.Dependency_Kind);
         end if;

         if Source.Index /= 0 then
            Source.Object :=
              Object_Name
                (Source_File_Name   => Main_Source_File,
                 Source_Index       => Source.Index,
                 Index_Separator    =>
                   Source.Language.Config.Multi_Unit_Object_Separator,
                 Object_File_Suffix =>
                   Source.Language.Config.Object_File_Suffix);

            Source.Dep_Name :=
              Dependency_Name
                (Source.Object, Source.Language.Config.Dependency_Kind);
         end if;

         --  Find the object file for that source. It could be either in the
         --  current project or in an extended project (it might actually not
         --  exist yet in the ultimate extending project, but if not found
         --  elsewhere that's where we'll expect to find it).

         Obj_Proj := Source.Project;

         while Obj_Proj /= No_Project loop
            if Obj_Proj.Object_Directory /= No_Path_Information then
               declare
                  Dir : constant String :=
                    Get_Name_String (Obj_Proj.Object_Directory.Display_Name);

                  Object_Path : constant String :=
                    Normalize_Pathname
                      (Name          => Get_Name_String (Source.Object),
                       Resolve_Links => Opt.Follow_Links_For_Files,
                       Directory     => Dir);

                  Obj_Path : constant Path_Name_Type :=
                    Create_Name (Object_Path);

                  Stamp : Time_Stamp_Type := Empty_Time_Stamp;

               begin
                  --  For specs, we do not check object files if there is a
                  --  body. This saves a system call. On the other hand, we do
                  --  need to know the object_path, in case the user has passed
                  --  the .ads on the command line to compile the spec only.

                  if Source.Kind /= Spec
                    or else Source.Unit = No_Unit_Index
                    or else Source.Unit.File_Names (Impl) = No_Source
                  then
                     Stamp := File_Stamp (Obj_Path);
                  end if;

                  if Stamp /= Empty_Time_Stamp
                    or else (Obj_Proj.Extended_By = No_Project
                             and then Source.Object_Project = No_Project)
                  then
                     Set_Object_Project (Dir, Obj_Proj, Obj_Path, Stamp);
                  end if;
               end;
            end if;

            Obj_Proj := Obj_Proj.Extended_By;
         end loop;

         if Source.Language.Config.Dependency_Kind /= None
            and then Source.Dep_Path = No_Path
         then
            --  If we have not found a dependency file in the object
            --  project, it means that the Source.Project is extended and that
            --  we are in gprls node. We need to look for an actual dependency
            --  file in the extended projects. If none is found, the dependency
            --  file is set in the ultimate extending project.

            Obj_Proj := Source.Project;

            while Obj_Proj /= No_Project loop
               if Obj_Proj.Object_Directory /= No_Path_Information then
                  declare
                     Dir : constant String :=
                             Get_Name_String
                               (Obj_Proj.Object_Directory.Display_Name);

                     Dep_Path_Name : constant String :=
                       Normalize_Pathname
                         (Name          => Get_Name_String (Source.Dep_Name),
                          Resolve_Links => Opt.Follow_Links_For_Files,
                          Directory     => Dir);

                     Dep_Path : constant Path_Name_Type :=
                                  Create_Name (Dep_Path_Name);

                     Stamp : Time_Stamp_Type := Empty_Time_Stamp;

                  begin
                     if Source.Kind /= Spec
                       or else Source.Unit = No_Unit_Index
                       or else Source.Unit.File_Names (Impl) = No_Source
                     then
                        Stamp := File_Stamp (Dep_Path);
                     end if;

                     if Stamp /= Empty_Time_Stamp
                       or else
                         (Source.Dep_Path = No_Path
                          and then Obj_Proj.Extended_By = No_Project)
                     then
                        Source.Dep_Path := Dep_Path;
                        Source.Dep_TS   := Unknown_Attributes;
                     end if;
                  end;
               end if;

               Obj_Proj := Obj_Proj.Extended_By;
            end loop;
         end if;

      elsif Source.Language.Config.Dependency_Kind = Makefile then
         declare
            Object_Dir : constant String :=
              Get_Name_String (Source.Project.Object_Directory.Display_Name);
            Dep_Path   : constant String :=
              Normalize_Pathname
                (Name          => Get_Name_String (Source.Dep_Name),
                 Resolve_Links => Opt.Follow_Links_For_Files,
                 Directory     => Object_Dir);
         begin
            Source.Dep_Path := Create_Name (Dep_Path);
            Source.Dep_TS   := Unknown_Attributes;
         end;
      end if;

      Source.Initialized := True;
   end Initialize_Source_Record;

   ---------------------------------
   -- Is_Ada_Predefined_File_Name --
   ---------------------------------

   function Is_Ada_Predefined_File_Name
     (Fname : File_Name_Type) return Boolean
   is
      subtype Str8 is String (1 .. 8);

      Predef_Names : constant array (1 .. 12) of Str8 :=
        ("ada     ",  -- Ada
         "interfac",  -- Interfaces
         "system  ",  -- System
         "gnat    ",  -- GNAT
         "calendar",  -- Calendar
         "machcode",  -- Machine_Code
         "unchconv",  -- Unchecked_Conversion
         "unchdeal",  -- Unchecked_Deallocation
         "directio",  -- Direct_IO
         "ioexcept",  -- IO_Exceptions
         "sequenio",  -- Sequential_IO
         "text_io "); -- Text_IO
   begin
      Get_Name_String (Fname);

      --  Remove extension (.ads/.adb) if present

      if Name_Len > 4 and then Name_Buffer (Name_Len - 3) = '.' then
         Name_Len := Name_Len - 4;
      end if;

      --  Definitely predefined if prefix is a- i- or s- followed by letter

      if Name_Len >=  3
        and then Name_Buffer (2) = '-'
        and then (Name_Buffer (1) = 'a'
                    or else
                  Name_Buffer (1) = 'g'
                    or else
                  Name_Buffer (1) = 'i'
                    or else
                  Name_Buffer (1) = 's')
        and then (Name_Buffer (3) in 'a' .. 'z'
                    or else
                  Name_Buffer (3) in 'A' .. 'Z')
      then
         return True;

      --  Definitely false if longer than 12 characters (8.3)

      elsif Name_Len > 8 then
         return False;
      end if;

      --  Otherwise check against special list, first padding to 8 characters

      while Name_Len < 8 loop
         Name_Len := Name_Len + 1;
         Name_Buffer (Name_Len) := ' ';
      end loop;

      for J in Predef_Names'Range loop
         if Name_Buffer (1 .. 8) = Predef_Names (J) then
            return True;
         end if;
      end loop;

      return False;
   end Is_Ada_Predefined_File_Name;

   ----------------------------
   -- Is_Ada_Predefined_Unit --
   ----------------------------

   function Is_Ada_Predefined_Unit (Unit : String) return Boolean is
      Lower_Unit : String := Unit;
   begin
      To_Lower (Lower_Unit);

      return Lower_Unit in "ada"
                         | "gnat"
                         | "interfaces"
                         | "system"
                         | "calendar"
                         | "machine_code"
                         | "unchecked_conversion"
                         | "unchecked_deallocation"
                         | "direct_io"
                         | "io_exceptions"
                         | "sequential_io"
                         | "text_io"
        or else Starts_With (Lower_Unit, "ada.")
        or else Starts_With (Lower_Unit, "gnat.")
        or else Starts_With (Lower_Unit, "system.")
        or else Starts_With (Lower_Unit, "interfaces.");
   end Is_Ada_Predefined_Unit;

   ----------------------------
   -- Is_Pragmas_Config_File --
   ----------------------------

   function Is_Pragmas_Config_File (Fname : File_Name_Type) return Boolean is
      Filename                  : constant String := Get_Name_String (Fname);
      Pragma_Config_File_Suffix : constant String := ".adc";

      E_First : constant Integer :=
                  Filename'Last - Pragma_Config_File_Suffix'Length + 1;
      E_Last  : constant Integer := Filename'Last;
   begin
      if Filename'Length > Pragma_Config_File_Suffix'Length then
         return (Filename (E_First .. E_Last) = Pragma_Config_File_Suffix);
      else
         return False;
      end if;
   end Is_Pragmas_Config_File;

   ----------------
   -- Is_Subunit --
   ----------------

   function Is_Subunit (Source : GPR.Source_Id) return Boolean is
      Src_Ind : Source_File_Index;

   begin
      if Source.Kind = Sep then
         return True;

      --  A Spec, a file based language source or a body with a spec cannot be
      --  a subunit.

      elsif Source.Kind = Spec
        or else Source.Unit = No_Unit_Index
        or else Other_Part (Source) /= No_Source
      then
         return False;
      end if;

      --  Here, we are assuming that the language is Ada, as it is the only
      --  unit based language that we know.

      pragma Assert
        (Source.Path /= No_Path_Information,
         "no path information for "
         & Get_Name_String (Source.File) & ' ' & Source.Locally_Removed'Img);

      Src_Ind :=
        Sinput.Load_File (Get_Name_String (Source.Path.Display_Name));

      return Sinput.Source_File_Is_Subunit (Src_Ind);
   end Is_Subunit;

   --------------
   -- Is_Valid --
   --------------

   function Is_Valid (File : Text_File) return Boolean is
   begin
      return File /= null;
   end Is_Valid;

   ----------
   -- Next --
   ----------

   procedure Next (Iter : in out Source_Info_Iterator) is
   begin
      if Iter.Next = 0 then
         Iter.Info := No_Source_Info;

      else
         Iter := Source_Info_Table.Table (Iter.Next);
      end if;
   end Next;

   --------------------
   -- Object_Project --
   --------------------

   function Object_Project
     (Project          : Project_Id;
      Must_Be_Writable : Boolean := False) return Project_Id
   is
      Result : Project_Id := No_Project;

      procedure Check_Project (P : Project_Id);
      --  Find a project with an object dir

      -------------------
      -- Check_Project --
      -------------------

      procedure Check_Project (P : Project_Id) is
      begin
         if P.Qualifier = Aggregate
           or else P.Qualifier = Aggregate_Library
         then
            declare
               List : Aggregated_Project_List := P.Aggregated_Projects;
            begin
               --  Look for a non aggregate project until one is found

               while Result = No_Project and then List /= null loop
                  Check_Project (List.Project);
                  List := List.Next;
               end loop;
            end;

         elsif P.Object_Directory.Name /= No_Path then
            if not Must_Be_Writable
              or else Is_Writable_File
                (Get_Name_String (P.Object_Directory.Display_Name))
            then
               Result := P;
            end if;
         end if;
      end Check_Project;

   begin
      Check_Project (Project);
      return Result;
   end Object_Project;

   ----------
   -- Open --
   ----------

   procedure Open (File : out Text_File; Name : String) is
      FD        : File_Descriptor;
      File_Name : String (1 .. Name'Length + 1);

   begin
      File_Name (1 .. Name'Length) := Name;
      File_Name (File_Name'Last) := ASCII.NUL;
      FD := Open_Read (Name => File_Name'Address,
                       Fmode => GNAT.OS_Lib.Text);

      if FD = Invalid_FD then
         File := null;

      else
         File := new Text_File_Data;
         File.FD := FD;
         File.Buffer_Len :=
           Read (FD => FD,
                 A  => File.Buffer'Address,
                 N  => File.Buffer'Length);

         if File.Buffer_Len = 0 then
            File.End_Of_File_Reached := True;
         else
            File.Cursor := 1;
         end if;
      end if;
   end Open;

   ---------
   -- Put --
   ---------

   procedure Put
     (Into_List  : in out Name_List_Index;
      From_List  : String_List_Id;
      In_Tree    : Project_Tree_Ref;
      Lower_Case : Boolean := False)
   is
      Shared  : constant Shared_Project_Tree_Data_Access := In_Tree.Shared;

      Current_Name : Name_List_Index;
      List         : String_List_Id;
      Element      : String_Element;
      Last         : Name_List_Index :=
                       Name_List_Table.Last (Shared.Name_Lists);
      Value        : Name_Id;

   begin
      Current_Name := Into_List;
      while Current_Name /= No_Name_List
        and then Shared.Name_Lists.Table (Current_Name).Next /= No_Name_List
      loop
         Current_Name := Shared.Name_Lists.Table (Current_Name).Next;
      end loop;

      List := From_List;
      while List /= Nil_String loop
         Element := Shared.String_Elements.Table (List);
         Value := Element.Value;

         if Lower_Case then
            Get_Name_String (Value);
            To_Lower (Name_Buffer (1 .. Name_Len));
            Value := Name_Find;
         end if;

         Name_List_Table.Append
           (Shared.Name_Lists, (Name => Value, Next => No_Name_List));

         Last := Last + 1;

         if Current_Name = No_Name_List then
            Into_List := Last;
         else
            Shared.Name_Lists.Table (Current_Name).Next := Last;
         end if;

         Current_Name := Last;

         List := Element.Next;
      end loop;
   end Put;

   procedure Put (File : Text_File; S : String) is
      Len : Integer;
   begin
      if File = null then
         GPR.Com.Fail ("Attempted to write on an invalid Text_File");

      elsif not File.Out_File then
         GPR.Com.Fail ("Attempted to write an in Text_File");
      end if;

      if File.Buffer_Len + S'Length > File.Buffer'Last then
         --  Write buffer
         Len := Write (File.FD, File.Buffer'Address, File.Buffer_Len);

         if Len /= File.Buffer_Len then
            GPR.Com.Fail ("Failed to write to an out Text_File");
         end if;

         File.Buffer_Len := 0;
      end if;

      File.Buffer (File.Buffer_Len + 1 .. File.Buffer_Len + S'Length) := S;
      File.Buffer_Len := File.Buffer_Len + S'Length;
   end Put;

   --------------
   -- Put_Line --
   --------------

   procedure Put_Line (File : Text_File; Line : String) is
      L : String (1 .. Line'Length + 1);
   begin
      L (1 .. Line'Length) := Line;
      L (L'Last) := ASCII.LF;
      Put (File, L);
   end Put_Line;

   ---------------------------
   -- Read_Source_Info_File --
   ---------------------------

   procedure Read_Source_Info_File (Tree : Project_Tree_Ref) is
      File : Text_File;
      Info : Source_Info_Iterator;
      Proj : Name_Id;

      procedure Report_Error;

      ------------------
      -- Report_Error --
      ------------------

      procedure Report_Error is
      begin
         Write_Line
           ("errors in source info file """
            & Tree.Source_Info_File_Name.all & '"');
         Tree.Source_Info_File_Exists := False;
      end Report_Error;

   begin
      Source_Info_Project_HTable.Reset;
      Source_Info_Table.Init;

      if Tree.Source_Info_File_Name = null then
         Tree.Source_Info_File_Exists := False;
         return;
      end if;

      Open (File, Tree.Source_Info_File_Name.all);

      if not Is_Valid (File) then
         if Opt.Verbosity_Level > Opt.Low then
            Write_Line
              ("source info file " & Tree.Source_Info_File_Name.all
               & " does not exist");
         end if;

         Tree.Source_Info_File_Exists := False;
         return;
      end if;

      Tree.Source_Info_File_Exists := True;

      if Opt.Verbosity_Level > Opt.Low then
         Write_Line
           ("Reading source info file " & Tree.Source_Info_File_Name.all);
      end if;

      Source_Loop :
      while not End_Of_File (File) loop
         Info := (new Source_Info_Data, 0);
         Source_Info_Table.Increment_Last;

         --  project name
         Get_Line (File, Name_Buffer, Name_Len);
         Proj := Name_Find;
         Info.Info.Project := Proj;
         Info.Next := Source_Info_Project_HTable.Get (Proj);
         Source_Info_Project_HTable.Set (Proj, Source_Info_Table.Last);

         if End_Of_File (File) then
            Report_Error;
            exit Source_Loop;
         end if;

         --  language name
         Get_Line (File, Name_Buffer, Name_Len);
         Info.Info.Language := Name_Find;

         if End_Of_File (File) then
            Report_Error;
            exit Source_Loop;
         end if;

         --  kind
         Get_Line (File, Name_Buffer, Name_Len);
         Info.Info.Kind := Source_Kind'Value (Name_Buffer (1 .. Name_Len));

         if End_Of_File (File) then
            Report_Error;
            exit Source_Loop;
         end if;

         --  display path name
         Get_Line (File, Name_Buffer, Name_Len);
         Info.Info.Display_Path_Name := Name_Find;
         Info.Info.Path_Name := Info.Info.Display_Path_Name;

         if End_Of_File (File) then
            Report_Error;
            exit Source_Loop;
         end if;

         --  optional fields

         Option_Loop :
         loop
            Get_Line (File, Name_Buffer, Name_Len);
            exit Option_Loop when Name_Len = 0;

            if Name_Len <= 2 then
               Report_Error;
               exit Source_Loop;

            else
               if Name_Buffer (1 .. 2) = "P=" then
                  Name_Buffer (1 .. Name_Len - 2) :=
                    Name_Buffer (3 .. Name_Len);
                  Name_Len := Name_Len - 2;
                  Info.Info.Path_Name := Name_Find;

               elsif Name_Buffer (1 .. 2) = "U=" then
                  Name_Buffer (1 .. Name_Len - 2) :=
                    Name_Buffer (3 .. Name_Len);
                  Name_Len := Name_Len - 2;
                  Info.Info.Unit_Name := Name_Find;

               elsif Name_Buffer (1 .. 2) = "I=" then
                  Info.Info.Index := Int'Value (Name_Buffer (3 .. Name_Len));

               elsif Name_Buffer (1 .. Name_Len) = "N=Y" then
                  Info.Info.Naming_Exception := Yes;

               elsif Name_Buffer (1 .. Name_Len) = "N=I" then
                  Info.Info.Naming_Exception := Inherited;

               else
                  Report_Error;
                  exit Source_Loop;
               end if;
            end if;
         end loop Option_Loop;

         Source_Info_Table.Table (Source_Info_Table.Last) := Info;
      end loop Source_Loop;

      Close (File);

   exception
      when others =>
         Close (File);
         Report_Error;
   end Read_Source_Info_File;

   -------------------
   -- Relative_Path --
   -------------------

   function Relative_Path
     (Pathname  : String;
      To        : String;
      Directory : Boolean := True) return String
   is
      function Ensure_Directory (Path : String) return String;
      --  Returns Path with an added directory separator if needed

      ----------------------
      -- Ensure_Directory --
      ----------------------

      function Ensure_Directory (Path : String) return String is
      begin
         if Path'Length = 0 then
            return "./";

         elsif not Directory or else Is_Directory_Separator (Path (Path'Last))
         then
            return Path;

         else
            return Path & Directory_Separator;
         end if;
      end Ensure_Directory;

      --  Local variables

      Dir_Sep_Map : constant Character_Mapping := To_Mapping ("\", "/");

      P  : String (1 .. Pathname'Length) := Pathname;
      T  : String (1 .. To'Length) := To;

      Pi : Natural; -- common prefix ending
      N  : Natural := 0;

   --  Start of processing for Relative_Path

   begin
      pragma Assert (Is_Absolute_Path (Pathname));
      pragma Assert (Is_Absolute_Path (To));

      --  Use canonical directory separator

      Translate (Source => P, Mapping => Dir_Sep_Map);
      Translate (Source => T, Mapping => Dir_Sep_Map);

      --  First check for common prefix

      Pi := 1;
      while Pi < P'Last and then Pi < T'Last and then P (Pi) = T (Pi) loop
         Pi := Pi + 1;
      end loop;

      --  Cut common prefix at a directory separator

      while Pi > P'First and then P (Pi) /= '/' loop
         Pi := Pi - 1;
      end loop;

      --  Count directory under prefix in P, these will be replaced by the
      --  corresponding number of "..".

      N := Ada.Strings.Fixed.Count (T (Pi + 1 .. T'Last), "/");

      if T (T'Last) /= '/' then
         N := N + 1;
      end if;

      return N * "../" & Ensure_Directory (P (Pi + 1 .. P'Last));
   end Relative_Path;

   ----------------------
   -- Set_Program_Name --
   ----------------------

   procedure Set_Program_Name (N : String) is
   begin
      Program_Name := new String'(N);
   end Set_Program_Name;

   -------------------
   -- Source_Dir_Of --
   -------------------

   function Source_Dir_Of (Source : Source_Id) return String is
      Path : constant String := Get_Name_String (Source.Path.Name);
   begin
      return Path (Path'First
                   .. Path'Last - Natural (Length_Of_Name (Source.File)));
   end Source_Dir_Of;

   --------------------
   -- Source_Info_Of --
   --------------------

   function Source_Info_Of (Iter : Source_Info_Iterator) return Source_Info is
   begin
      return Iter.Info;
   end Source_Info_Of;

   -----------
   -- Split --
   -----------

   function Split
     (Source : String; Separator : String) return Name_Array_Type
   is
      Start  : Positive := Source'First;
      Finish : Positive;

      package Name_Ids is new Ada.Containers.Vectors (Positive, Name_Id);
      List : Name_Ids.Vector;

      procedure Add_String (S : String);

      ----------------
      -- Add_String --
      ----------------

      procedure Add_String (S : String) is
      begin
         if S'Length > 0 then
            List.Append (Get_Name_Id (S));
         end if;
      end Add_String;

   begin
      if Separator'Length = 0 or else Index (Source, Separator) = 0 then
         --  List with one string = Argument
         Add_String (Source);

      else
         if Index (Source, Separator) = Start then
            Start := Start + Separator'Length;
         end if;

         loop
            if Index (Source (Start .. Source'Last), Separator) = 0 then
               Add_String (Source (Start .. Source'Last));
               exit;

            else
               Finish := Index (Source (Start .. Source'Last), Separator) - 1;
               Add_String (Source (Start .. Finish));
               Start := Finish + 1 + Separator'Length;
               exit when Start > Source'Last;
            end if;
         end loop;
      end if;

      return Result : Name_Array_Type (1 .. Integer (List.Length)) do
         for J in Result'Range loop
            Result (J) := List.Element (J);
         end loop;
      end return;
   end Split;

   -------------------
   -- To_Time_Stamp --
   -------------------

   function To_Time_Stamp
     (Time : Calendar.Time) return Stamps.Time_Stamp_Type is
   begin
      return Time_Stamp_Type (Image (Time, "%Y%m%d%H%M%S"));
   end To_Time_Stamp;

   ----------------------
   -- To_UTC_Timestamp --
   ----------------------

   function To_UTC_Time_Stamp
     (Time : Calendar.Time) return Stamps.Time_Stamp_Type
   is
      use type Ada.Calendar.Time;
   begin
      return To_Time_Stamp (Time - Duration (UTC_Time_Offset (Time)) * 60);
   end To_UTC_Time_Stamp;

   --------------
   -- UTC_Time --
   --------------

   function UTC_Time return Time_Stamp_Type is
   begin
      return To_UTC_Time_Stamp (Ada.Calendar.Clock);
   end UTC_Time;

   --------------
   -- Value_Of --
   --------------

   function Value_Of
     (Variable : Variable_Value;
      Default  : String) return String is
   begin
      if Variable.Kind /= Single
        or else Variable.Default
        or else Variable.Value = No_Name
      then
         return Default;
      else
         return Get_Name_String (Variable.Value);
      end if;
   end Value_Of;

   function Value_Of
     (Index    : Name_Id;
      In_Array : Array_Element_Id;
      Shared   : Shared_Project_Tree_Data_Access) return Name_Id
   is
      Current    : Array_Element_Id;
      Element    : Array_Element;
      Real_Index : Name_Id := Index;

   begin
      Current := In_Array;

      if Current = No_Array_Element then
         return No_Name;
      end if;

      Element := Shared.Array_Elements.Table (Current);

      if not Element.Index_Case_Sensitive then
         Get_Name_String (Index);
         To_Lower (Name_Buffer (1 .. Name_Len));
         Real_Index := Name_Find;
      end if;

      while Current /= No_Array_Element loop
         Element := Shared.Array_Elements.Table (Current);

         if Real_Index = Element.Index then
            exit when Element.Value.Kind /= Single;
            exit when Element.Value.Value = Empty_String;
            return Element.Value.Value;
         else
            Current := Element.Next;
         end if;
      end loop;

      return No_Name;
   end Value_Of;

   function Value_Of
     (Index                  : Name_Id;
      Src_Index              : Int := 0;
      In_Array               : Array_Element_Id;
      Shared                 : Shared_Project_Tree_Data_Access;
      Force_Lower_Case_Index : Boolean := False;
      Allow_Wildcards        : Boolean := False) return Variable_Value
   is
      Current      : Array_Element_Id;
      Element      : Array_Element;
      Real_Index_1 : Name_Id;
      Real_Index_2 : Name_Id;

   begin
      Current := In_Array;

      if Current = No_Array_Element then
         return Nil_Variable_Value;
      end if;

      Element := Shared.Array_Elements.Table (Current);

      Real_Index_1 := Index;

      if (not Element.Index_Case_Sensitive or else Force_Lower_Case_Index)
        and then Index /= All_Other_Names
      then
         Get_Name_String (Index);
         To_Lower (Name_Buffer (1 .. Name_Len));
         Real_Index_1 := Name_Find;
      end if;

      while Current /= No_Array_Element loop
         Element := Shared.Array_Elements.Table (Current);
         Real_Index_2 := Element.Index;

         if (not Element.Index_Case_Sensitive or else Force_Lower_Case_Index)
           and then Element.Index /= All_Other_Names
         then
            Get_Name_String (Element.Index);
            To_Lower (Name_Buffer (1 .. Name_Len));
            Real_Index_2 := Name_Find;
         end if;

         if Src_Index = Element.Src_Index
           and then
             (Real_Index_1 = Real_Index_2
              or else (Real_Index_2 /= All_Other_Names
                       and then Allow_Wildcards
                       and then
                       Match
                         (Get_Name_String (Real_Index_1),
                          Compile
                            (Get_Name_String (Real_Index_2), Glob => True))))
         then
            return Element.Value;
         else
            Current := Element.Next;
         end if;
      end loop;

      return Nil_Variable_Value;
   end Value_Of;

   function Value_Of
     (Name                    : Name_Id;
      Index                   : Int := 0;
      Attribute_Or_Array_Name : Name_Id;
      In_Package              : Package_Id;
      Shared                  : Shared_Project_Tree_Data_Access;
      Force_Lower_Case_Index  : Boolean := False;
      Allow_Wildcards         : Boolean := False) return Variable_Value
   is
      The_Array     : Array_Element_Id;
      The_Attribute : Variable_Value := Nil_Variable_Value;

   begin
      if In_Package /= No_Package then

         --  First, look if there is an array element that fits

         The_Array :=
           Value_Of
             (Name      => Attribute_Or_Array_Name,
              In_Arrays => Shared.Packages.Table (In_Package).Decl.Arrays,
              Shared    => Shared);
         The_Attribute :=
           Value_Of
             (Index                  => Name,
              Src_Index              => Index,
              In_Array               => The_Array,
              Shared                 => Shared,
              Force_Lower_Case_Index => Force_Lower_Case_Index,
              Allow_Wildcards        => Allow_Wildcards);

         --  If there is no array element, look for a variable

         if The_Attribute = Nil_Variable_Value then
            The_Attribute :=
              Value_Of
                (Variable_Name => Attribute_Or_Array_Name,
                 In_Variables  => Shared.Packages.Table
                   (In_Package).Decl.Attributes,
                 Shared        => Shared);
         end if;
      end if;

      return The_Attribute;
   end Value_Of;

   function Value_Of
     (Index     : Name_Id;
      In_Array  : Name_Id;
      In_Arrays : Array_Id;
      Shared    : Shared_Project_Tree_Data_Access) return Name_Id
   is
      Current   : Array_Id;
      The_Array : Array_Data;

   begin
      Current := In_Arrays;
      while Current /= No_Array loop
         The_Array := Shared.Arrays.Table (Current);
         if The_Array.Name = In_Array then
            return Value_Of
              (Index, In_Array => The_Array.Value, Shared => Shared);
         else
            Current := The_Array.Next;
         end if;
      end loop;

      return No_Name;
   end Value_Of;

   function Value_Of
     (Name      : Name_Id;
      In_Arrays : Array_Id;
      Shared    : Shared_Project_Tree_Data_Access) return Array_Element_Id
   is
      Current   : Array_Id;
      The_Array : Array_Data;

   begin
      Current := In_Arrays;
      while Current /= No_Array loop
         The_Array := Shared.Arrays.Table (Current);

         if The_Array.Name = Name then
            return The_Array.Value;
         else
            Current := The_Array.Next;
         end if;
      end loop;

      return No_Array_Element;
   end Value_Of;

   function Value_Of
     (Name        : Name_Id;
      In_Packages : Package_Id;
      Shared      : Shared_Project_Tree_Data_Access) return Package_Id
   is
      Current     : Package_Id;
      The_Package : Package_Element;

   begin
      Current := In_Packages;
      while Current /= No_Package loop
         The_Package := Shared.Packages.Table (Current);
         exit when The_Package.Name /= No_Name
           and then The_Package.Name = Name;
         Current := The_Package.Next;
      end loop;

      return Current;
   end Value_Of;

   function Value_Of
     (Variable_Name : Name_Id;
      In_Variables  : Variable_Id;
      Shared        : Shared_Project_Tree_Data_Access) return Variable_Value
   is
      Current      : Variable_Id;
      The_Variable : Variable;

   begin
      Current := In_Variables;
      while Current /= No_Variable loop
         The_Variable := Shared.Variable_Elements.Table (Current);

         if Variable_Name = The_Variable.Name then
            return The_Variable.Value;
         else
            Current := The_Variable.Next;
         end if;
      end loop;

      return Nil_Variable_Value;
   end Value_Of;

   ------------------------
   -- Write_Program_Name --
   ------------------------

   procedure Write_Program_Name is
   begin
      if Program_Name /= null then
         Write_Str (Program_Name.all & ": ");
      end if;
   end Write_Program_Name;

   ----------------------------
   -- Write_Source_Info_File --
   ----------------------------

   procedure Write_Source_Info_File (Tree : Project_Tree_Ref) is
      Iter   : Source_Iterator := For_Each_Source (Tree);
      Source : GPR.Source_Id;
      File   : Text_File;

   begin
      if Opt.Verbosity_Level > Opt.Low then
         Write_Line ("Writing new source info file " &
                     Tree.Source_Info_File_Name.all);
      end if;

      Create (File, Tree.Source_Info_File_Name.all);

      if not Is_Valid (File) then
         Write_Line
           ("warning: unable to create source info file """
            & Tree.Source_Info_File_Name.all & '"');
         return;
      end if;

      loop
         Source := Element (Iter);
         exit when Source = No_Source;

         if not Source.Locally_Removed
           and then Source.Replaced_By = No_Source
         then
            --  Project name

            Put_Line (File, Get_Name_String (Source.Project.Name));

            --  Language name

            Put_Line (File, Get_Name_String (Source.Language.Name));

            --  Kind

            Put_Line (File, Source.Kind'Img);

            --  Display path name

            Put_Line (File, Get_Name_String (Source.Path.Display_Name));

            --  Optional lines:

            --  Path name (P=)

            if Source.Path.Name /= Source.Path.Display_Name then
               Put (File, "P=");
               Put_Line (File, Get_Name_String (Source.Path.Name));
            end if;

            --  Unit name (U=)

            if Source.Unit /= No_Unit_Index then
               Put (File, "U=");
               Put_Line (File, Get_Name_String (Source.Unit.Name));
            end if;

            --  Multi-source index (I=)

            if Source.Index /= 0 then
               Put (File, "I=");
               Put_Line (File, Source.Index'Img);
            end if;

            --  Naming exception ("N=T");

            if Source.Naming_Exception = Yes then
               Put_Line (File, "N=Y");

            elsif Source.Naming_Exception = Inherited then
               Put_Line (File, "N=I");
            end if;

            --  Empty line to indicate end of info on this source

            Put_Line (File, "");
         end if;

         Next (Iter);
      end loop;

      Close (File);
   end Write_Source_Info_File;

   ---------------
   -- Write_Str --
   ---------------

   procedure Write_Str
     (S          : String;
      Max_Length : Positive;
      Separator  : Character)
   is
      First : Positive := S'First;
      Last  : Natural  := S'Last;

   begin
      --  Nothing to do for empty strings

      if S'Length > 0 then

         --  Start on a new line if current line is already longer than
         --  Max_Length.

         if Positive (Column) >= Max_Length then
            Write_Eol;
         end if;

         --  If length of remainder is longer than Max_Length, we need to
         --  cut the remainder in several lines.

         while Positive (Column) + S'Last - First > Max_Length loop

            --  Try the maximum length possible

            Last := First + Max_Length - Positive (Column);

            --  Look for last Separator in the line

            while Last >= First and then S (Last) /= Separator loop
               Last := Last - 1;
            end loop;

            --  If we do not find a separator, we output the maximum length
            --  possible.

            if Last < First then
               Last := First + Max_Length - Positive (Column);
            end if;

            Write_Line (S (First .. Last));

            --  Set the beginning of the new remainder

            First := Last + 1;
         end loop;

         --  What is left goes to the buffer, without EOL

         Write_Str (S (First .. S'Last));
      end if;
   end Write_Str;

   Libgcc_Subdir_Ptr : Interfaces.C.Strings.chars_ptr;
   pragma Import (C, Libgcc_Subdir_Ptr, "__gnat_default_libgcc_subdir");
   --  Pointer to string indicating the installation subdirectory where a
   --  default shared libgcc might be found.

   package Project_Name_Boolean_Htable is new Simple_HTable
     (Header_Num => Header_Num,
      Element    => Boolean,
      No_Element => False,
      Key        => Name_Id,
      Hash       => Hash,
      Equal      => "=");

   Project_Failure : Project_Name_Boolean_Htable.Instance :=
                       Project_Name_Boolean_Htable.Nil;
   --  Record a boolean for project having failed to compile cleanly

   -------------------------------
   -- Binder_Exchange_File_Name --
   -------------------------------

   function Binder_Exchange_File_Name
     (Main_Base_Name : File_Name_Type; Prefix : Name_Id) return String_Access
   is
      File_Name : constant String := Get_Name_String (Main_Base_Name);
   begin
      Get_Name_String (Prefix);
      Add_Str_To_Name_Buffer (File_Name);
      Add_Str_To_Name_Buffer (Binder_Exchange_Suffix);
      return new String'(Name_Buffer (1 .. Name_Len));
   end Binder_Exchange_File_Name;

   ------------------------------
   -- Check_Version_And_Help_G --
   ------------------------------

   --  Common switches for GNU tools

   Version_Switch : constant String := "--version";
   Help_Switch    : constant String := "--help";

   procedure Check_Version_And_Help_G
     (Tool_Name : String; Initial_Year : String)
   is
      Version_Switch_Present : Boolean := False;
      Help_Switch_Present    : Boolean := False;
      Next_Arg               : Natural;

   begin
      --  First check for --version or --help

      Next_Arg := 1;
      while Next_Arg <= Argument_Count loop
         declare
            Next_Argv : constant String := Argument (Next_Arg);
         begin
            if Next_Argv = Version_Switch then
               Version_Switch_Present := True;

            elsif Next_Argv = Help_Switch then
               Help_Switch_Present := True;
            end if;

            Next_Arg := Next_Arg + 1;
         end;
      end loop;

      --  If --version was used, display version and exit

      if Version_Switch_Present then
         Display_Version (Tool_Name, Initial_Year);

         Put_Line (Free_Software);
         New_Line;

         OS_Exit (0);
      end if;

      --  If --help was used, display help and exit

      if Help_Switch_Present then
         Usage;
         New_Line;
         Put_Line ("Report bugs to report@adacore.com");
         OS_Exit (0);
      end if;
   end Check_Version_And_Help_G;

   ---------------------
   -- Create_Sym_Link --
   ---------------------

   procedure Create_Sym_Link (From, To : String) is

      function Symlink
        (Oldpath : System.Address;
         Newpath : System.Address) return Integer;
      pragma Import (C, Symlink, "__gnat_symlink");

      C_From  : constant String := From & ASCII.NUL;
      C_To    : constant String :=
                  Relative_Path
                    (Containing_Directory (To), Containing_Directory (From))
                  & Ada.Directories.Simple_Name (To) & ASCII.NUL;
      Result  : Integer;
      Success : Boolean;
      pragma Unreferenced (Result);

   begin
      Delete_File (From, Success);
      Result := Symlink (C_To'Address, C_From'Address);
   end Create_Sym_Link;

   ----------------------
   -- Create_Sym_Links --
   ----------------------

   procedure Create_Sym_Links
     (Lib_Path    : String;
      Lib_Version : String;
      Lib_Dir     : String;
      Maj_Version : String)
   is
      function Symlink
        (Oldpath : System.Address;
         Newpath : System.Address) return Integer;
      pragma Import (C, Symlink, "__gnat_symlink");

      Version_Path : String_Access;

      Success : Boolean;
      Result  : Integer;
      pragma Unreferenced (Result);

   begin
      Version_Path := new String (1 .. Lib_Version'Length + 1);
      Version_Path (1 .. Lib_Version'Length) := Lib_Version;
      Version_Path (Version_Path'Last)       := ASCII.NUL;

      if Maj_Version'Length = 0 then
         declare
            Newpath : String (1 .. Lib_Path'Length + 1);
         begin
            Newpath (1 .. Lib_Path'Length) := Lib_Path;
            Newpath (Newpath'Last)         := ASCII.NUL;
            Delete_File (Lib_Path, Success);
            Result := Symlink (Version_Path (1)'Address, Newpath'Address);
         end;

      else
         declare
            Newpath1 : String (1 .. Lib_Path'Length + 1);
            Maj_Path : constant String :=
                         Lib_Dir & Directory_Separator & Maj_Version;
            Newpath2 : String (1 .. Maj_Path'Length + 1);
            Maj_Ver  : String (1 .. Maj_Version'Length + 1);

         begin
            Newpath1 (1 .. Lib_Path'Length) := Lib_Path;
            Newpath1 (Newpath1'Last)        := ASCII.NUL;

            Newpath2 (1 .. Maj_Path'Length) := Maj_Path;
            Newpath2 (Newpath2'Last)        := ASCII.NUL;

            Maj_Ver (1 .. Maj_Version'Length) := Maj_Version;
            Maj_Ver (Maj_Ver'Last)            := ASCII.NUL;

            Delete_File (Maj_Path, Success);

            Result := Symlink (Version_Path (1)'Address, Newpath2'Address);

            Delete_File (Lib_Path, Success);

            Result := Symlink (Maj_Ver'Address, Newpath1'Address);
         end;
      end if;
   end Create_Sym_Links;

   ------------------------------------
   -- Display_Usage_Version_And_Help --
   ------------------------------------

   procedure Display_Usage_Version_And_Help is
   begin
      Put_Line ("  --version   Display version and exit");
      Put_Line ("  --help      Display usage and exit");
      New_Line;
   end Display_Usage_Version_And_Help;

   ---------------------
   -- Display_Version --
   ---------------------

   procedure Display_Version
     (Tool_Name : String; Initial_Year : String) is
   begin
      Put_Line (Tool_Name & " " & Gpr_Version_String);

      Put ("Copyright (C) ");
      Put (Initial_Year);
      Put ('-');
      Put (Current_Year);
      Put (", ");
      Put (Copyright_Holder);
      New_Line;
   end Display_Version;
   ----------------------
   -- Ensure_Directory --
   ----------------------

   function Ensure_Directory (Path : String) return String is
   begin
      if Path'Length = 0
        or else Is_Directory_Separator (Path (Path'Last))
      then
         return Path;
      else
         return Path & Directory_Separator;
      end if;
   end Ensure_Directory;

   ----------------------
   -- Ensure_Extension --
   ----------------------

   function Ensure_Extension (Filename : String; Ext : String) return String is
   begin
      for Char of reverse Filename loop
         if Char = '.' then
            return Filename;
         elsif Is_Directory_Separator (Char) then
            exit;
         end if;
      end loop;

      return Filename & Ext;
   end Ensure_Extension;

   -------------------
   -- Ensure_Suffix --
   -------------------

   function Ensure_Suffix (Item : String; Suffix : String) return String is
   begin
      if Item'Length >= Suffix'Length
        and then Item (Item'Last - Suffix'Length + 1 .. Item'Last) = Suffix
      then
         return Item;
      else
         return Item & Suffix;
      end if;
   end Ensure_Suffix;

--     ---------------
--     -- Error_Msg --
--     ---------------
--
--     procedure Error_Msg (Msg : String; Flag_Location : Source_Ptr) is
--        pragma Warnings (Off, Msg);
--        pragma Warnings (Off, Flag_Location);
--     begin
--        null;
--     end Error_Msg;
--
--     -----------------
--     -- Error_Msg_S --
--     -----------------
--
--     procedure Error_Msg_S (Msg : String) is
--        pragma Warnings (Off, Msg);
--     begin
--        null;
--     end Error_Msg_S;
--
--     ------------------
--     -- Error_Msg_SC --
--     ------------------
--
--     procedure Error_Msg_SC (Msg : String) is
--        pragma Warnings (Off, Msg);
--     begin
--        null;
--     end Error_Msg_SC;
--
--     ------------------
--     -- Error_Msg_SP --
--     ------------------
--
--     procedure Error_Msg_SP (Msg : String) is
--        pragma Warnings (Off, Msg);
--     begin
--        null;
--     end Error_Msg_SP;

   --------------
   -- File_MD5 --
   --------------

   function File_MD5 (Pathname : String) return Message_Digest is
      use Stream_IO;

      C : Context;
      S : Stream_IO.File_Type;
      B : Stream_Element_Array (1 .. 100 * 1024);
      --  Buffer to read chunk of data
      L : Stream_Element_Offset;
   begin
      Open (S, In_File, Pathname);

      while not End_Of_File (S) loop
         Read (S, B, L);
         Update (C, B (1 .. L));
      end loop;

      Close (S);

      return Digest (C);
   end File_MD5;

   --------------
   -- As_RPath --
   --------------

   function As_RPath
     (Path : String; Case_Sensitive : Boolean) return String
   is
      Dir_Sep_Map : constant Character_Mapping := To_Mapping ("\", "/");
   begin
      return Translate
        (Normalize_Pathname
           (Path,
            Resolve_Links  => Opt.Follow_Links_For_Dirs,
            Case_Sensitive => Case_Sensitive),
         Mapping => Dir_Sep_Map);
   end As_RPath;

   --------------------
   -- Relative_RPath --
   --------------------

   function Relative_RPath (Dest, Src, Origin : String) return String is

      --  Rpaths are always considered case sensitive, as it's a runtime
      --  property of dynamic objects, so in case of cross compilation is
      --  independent of the host's way of handling case sensitivity.

      RP_Src              : constant String := As_RPath (Src, False);
      RP_Dest             : constant String := As_RPath (Dest, True);
      RP_Dest_Insensitive : constant String := As_RPath (Dest, False);

   begin
      declare
         Len : constant Natural := Common_Path_Prefix_Length
           (RP_Src, RP_Dest_Insensitive);
      begin
         if Len = 0 then
            --  No common prefix: return an absolute path
            return RP_Dest;

         else
            declare
               Sep_Mode     : Boolean := True;
               Subdir_Count : Natural := 0;
            begin
               --  Compute the relative path from Src to Dest. For this we
               --  need to find the number of subdirectories from the common
               --  prefix to Src.

               for I in RP_Src'First + Len .. RP_Src'Last loop
                  if RP_Src (I) = '/' then
                     Sep_Mode := True;

                  elsif Sep_Mode then
                     --  If the previous characters were separators, we are now
                     --  reading a new subdir. Sep_Mode is initialy True so
                     --  that we get here if the first character we see is not
                     --  a separator.

                     Subdir_Count := Subdir_Count + 1;
                     Sep_Mode := False;
                  end if;
               end loop;

               return Origin & "/" & Subdir_Count * "../"
                 & RP_Dest (RP_Dest'First + Len .. RP_Dest'Last);
            end;
         end if;
      end;
   end Relative_RPath;

   ------------------
   -- Concat_Paths --
   ------------------

   function Concat_Paths
     (List      : String_Vectors.Vector;
      Separator : String) return String
   is
      Length : Natural := Natural (List.Length - 1) * Separator'Length;
   begin
      for Path of List loop
         Length := Length + Path'Length;
      end loop;

      declare
         Ret : String (1 .. Length);
         Idx : Integer := 1;
      begin
         for Path of List loop
            Ret (Idx .. Idx + Path'Length - 1) := Path;
            Idx := Idx + Path'Length;

            if Idx < Ret'Last then
               Ret (Idx .. Idx + Separator'Length - 1) := Separator;
               Idx := Idx + Separator'Length;
            end if;
         end loop;

         return Ret;
      end;
   end Concat_Paths;

   ----------------------
   -- To_Argument_List --
   ----------------------

   function To_Argument_List
     (List : String_Vectors.Vector) return Argument_List
   is
      Ret : Argument_List (1 .. Natural (List.Length));
   begin
      for J in 1 .. List.Last_Index loop
         Ret (J) := new String'(List (J));
      end loop;

      return Ret;
   end To_Argument_List;

   -----------
   -- Slice --
   -----------

   function Slice
     (List : String_Vectors.Vector;
      From, To : Positive) return String_Vectors.Vector
   is
      Ret : String_Vectors.Vector;
   begin
      for J in From .. To loop
         Ret.Append (List (J));
      end loop;

      return Ret;
   end Slice;

   ------------------------------
   -- Get_Compiler_Driver_Path --
   ------------------------------

   function Get_Compiler_Driver_Path
     (Project : Project_Id;
      Lang    : Language_Ptr) return String_Access is
   begin
      if Lang.Config.Compiler_Driver_Path = null then
         declare
            CL : constant Language_Maps.Cursor :=
                   Compiler_Subst_HTable.Find (Lang.Name);
            Compiler : constant Name_Id :=
                         (if Language_Maps.Has_Element (CL)
                          then Language_Maps.Element (CL)
                          else Name_Id (Lang.Config.Compiler_Driver));
            --  If --compiler-subst was used to specify an alternate compiler,
            --  then Language_Maps.Has_Element (CL). In other case set Compiler
            --  to the Compiler_Driver from the config file.
         begin
            --  No compiler found, return now

            if Compiler = No_Name then
               return null;
            end if;

            declare
               Compiler_Name : constant String :=
                                 (if CodePeer_Mode then "codepeer-gcc"
                                  elsif GnatProve_Mode
                                    and then Lang.Name = Name_Ada
                                  then "gnat2why"
                                  else Get_Name_String (Compiler));
            begin
               if Compiler_Name = "" then
                  return null;
               end if;

               Lang.Config.Compiler_Driver_Path :=
                 Locate_Exec_On_Path (Compiler_Name);

               if Lang.Config.Compiler_Driver_Path = null then
                  Err.Error_Msg
                    (Gprbuild_Flags,
                     "unable to locate """ & Compiler_Name & '"',
                     Project => Project);
                  return null;
               end if;
            end;
         end;
      end if;

      return Lang.Config.Compiler_Driver_Path;
   end Get_Compiler_Driver_Path;

   ----------------------------
   -- Find_Binding_Languages --
   ----------------------------

   procedure Find_Binding_Languages
     (Tree         : Project_Tree_Ref;
      Root_Project : Project_Id)
   is
      Data    : constant Builder_Data_Access := Builder_Data (Tree);
      B_Index : Binding_Data;

      Language_Name      : Name_Id;
      Binder_Driver_Name : File_Name_Type := No_File;
      Binder_Driver_Path : String_Access;
      Binder_Prefix      : Name_Id;
      Language           : Language_Ptr;

      Config  : Language_Config;
      Project : Project_List;

   begin
      --  Have we already processed this tree ?

      if Data.There_Are_Binder_Drivers
        and then Data.Binding /= null
      then
         return;
      end if;

      if Current_Verbosity = High then
         Debug_Output ("Find_Binding_Languages for", Debug_Name (Tree));
      end if;

      Data.There_Are_Binder_Drivers := False;

      Project := Tree.Projects;
      while Project /= null loop
         Language := Project.Project.Languages;

         while Language /= No_Language_Index loop
            Config := Language.Config;

            Binder_Driver_Name := Config.Binder_Driver;

            if Language.First_Source /= No_Source
              and then Binder_Driver_Name /= No_File
            then
               Data.There_Are_Binder_Drivers := True;
               Language_Name := Language.Name;

               B_Index := Data.Binding;
               while B_Index /= null
                 and then B_Index.Language_Name /= Language_Name
               loop
                  B_Index := B_Index.Next;
               end loop;

               if B_Index = null then
                  Get_Name_String (Binder_Driver_Name);
                  Binder_Driver_Path :=
                    Locate_Exec_On_Path (Name_Buffer (1 .. Name_Len));

                  if Binder_Driver_Path = null then
                     Fail_Program
                       (Tree,
                        "unable to find binder driver " &
                        Name_Buffer (1 .. Name_Len));
                  end if;

                  if Current_Verbosity = High then
                     Debug_Output
                       ("Binder_Driver=" & Binder_Driver_Path.all
                        & " for Lang", Language_Name);
                  end if;

                  if Config.Binder_Prefix = No_Name then
                     Binder_Prefix := Empty_String;
                  else
                     Binder_Prefix := Config.Binder_Prefix;
                  end if;

                  B_Index := Data.Binding;
                  while B_Index /= null loop
                     if Binder_Prefix = B_Index.Binder_Prefix then
                        Fail_Program
                          (Tree,
                           "binding prefix cannot be the same for"
                           & " two languages",
                           Exit_Code => E_General);
                     end if;
                     B_Index := B_Index.Next;
                  end loop;

                  Data.Binding := new Binding_Data_Record'
                    (Language           => Language,
                     Language_Name      => Language_Name,
                     Binder_Driver_Name => Binder_Driver_Name,
                     Binder_Driver_Path => Binder_Driver_Path,
                     Binder_Prefix      => Binder_Prefix,
                     Next               => Data.Binding);
               end if;
            end if;

            Language := Language.Next;
         end loop;

         Project := Project.Next;
      end loop;

      if Root_Project.Qualifier = Aggregate then
         declare
            Agg : Aggregated_Project_List := Root_Project.Aggregated_Projects;
         begin
            while Agg /= null loop
               Find_Binding_Languages (Agg.Tree, Agg.Project);
               Agg := Agg.Next;
            end loop;
         end;
      end if;
   end Find_Binding_Languages;

   ----------------
   -- Get_Target --
   ----------------

   function Get_Target return String is
   begin
      if Target_Name = null or else Target_Name.all = "" then
         return Sdefault.Hostname;
      else
         return Target_Name.all;
      end if;
   end Get_Target;

   --------------------
   -- Locate_Runtime --
   --------------------

   procedure Locate_Runtime
     (Project_Tree : Project_Tree_Ref;
      Language     : Name_Id)
   is
      function Is_RTS_Directory (Path : String) return Boolean;
      --  Returns True if Path is a directory for a runtime. This simply check
      --  that Path has a "adalib" subdirectoy, which is a property for
      --  runtimes on the project path.

      function Is_Base_Name (Path : String) return Boolean;
      --  Returns True if Path has no directory separator

      ----------------------
      -- Is_RTS_Directory --
      ----------------------

      function Is_RTS_Directory (Path : String) return Boolean is
      begin
         return Is_Directory (Path & Directory_Separator & "adalib");
      end Is_RTS_Directory;

      --  Local declarations

      function Find_Rts_In_Path is new GPR.Env.Find_Name_In_Path
        (Check_Filename => Is_RTS_Directory);

      ------------------
      -- Is_Base_Name --
      ------------------

      function Is_Base_Name (Path : String) return Boolean is
      begin
         for I in Path'Range loop
            if Is_Directory_Separator (Path (I)) then
               return False;
            end if;
         end loop;
         return True;
      end Is_Base_Name;

      RTS_Name : constant String := GPR.Conf.Runtime_Name_For (Language);

      Full_Path : String_Access;

   begin
      Full_Path := Find_Rts_In_Path (Root_Environment.Project_Path, RTS_Name);
      if Full_Path /= null then
         GPR.Conf.Set_Runtime_For
           (Language, Normalize_Pathname (Full_Path.all));
         Free (Full_Path);

      elsif not Is_Base_Name (RTS_Name) then
         Fail_Program
           (Project_Tree, "cannot find RTS " & RTS_Name,
            Exit_Code => E_General);
      end if;
   end Locate_Runtime;

   ------------------------------
   -- Look_For_Default_Project --
   ------------------------------

   procedure Look_For_Default_Project (Never_Fail : Boolean := False) is
   begin
      if No_Project_File then
         No_Project_File_Found := True;

      else
         No_Project_File_Found := False;

         if Is_Regular_File (Default_Project_File_Name) then
            Project_File_Name := new String'(Default_Project_File_Name);

         else
            --  Check if there is a single project file in the current
            --  directory. If there is one and only one, use it.

            declare
               Dir : Dir_Type;
               Str : String (1 .. 255);
               Last : Natural;
               Single : String_Access := null;

            begin
               No_Project_File_Found := True;

               Open (Dir, ".");

               loop
                  Read (Dir, Str, Last);
                  exit when Last = 0;

                  if Last > Project_File_Extension'Length
                    and then Is_Regular_File (Str (1 .. Last))
                  then
                     Canonical_Case_File_Name (Str (1 .. Last));

                     if Str (Last - Project_File_Extension'Length + 1 .. Last)
                       = Project_File_Extension
                     then
                        No_Project_File_Found := False;

                        if Single = null then
                           Single := new String'(Str (1 .. Last));

                        else
                           --  There are several project files in the current
                           --  directory. Reset Single to null and exit.

                           Single := null;
                           exit;
                        end if;
                     end if;
                  end if;
               end loop;

               Close (Dir);

               Project_File_Name := Single;
            end;
         end if;
      end if;

      if No_Project_File_Found or else
        (Never_Fail and then Project_File_Name = null)
      then
         Project_File_Name :=
           new String'(Executable_Prefix_Path & Implicit_Project_File_Path);

         if not Is_Regular_File (Project_File_Name.all) then
            Project_File_Name := null;
         end if;
      end if;

      if not Quiet_Output and then Project_File_Name /= null then
         Put ("using project file ");
         Put_Line (Project_File_Name.all);
      end if;
   end Look_For_Default_Project;

   -------------------
   -- Major_Id_Name --
   -------------------

   function Major_Id_Name
     (Lib_Filename : String;
      Lib_Version  : String)
      return String
   is
      Maj_Version : constant String := Lib_Version;
      Last_Maj    : Positive;
      Last        : Positive;
      Ok_Maj      : Boolean := False;

   begin
      Last_Maj := Maj_Version'Last;
      while Last_Maj > Maj_Version'First loop
         if Maj_Version (Last_Maj) in '0' .. '9' then
            Last_Maj := Last_Maj - 1;

         else
            Ok_Maj := Last_Maj /= Maj_Version'Last and then
            Maj_Version (Last_Maj) = '.';

            if Ok_Maj then
               Last_Maj := Last_Maj - 1;
            end if;

            exit;
         end if;
      end loop;

      if Ok_Maj then
         Last := Last_Maj;
         while Last > Maj_Version'First loop
            if Maj_Version (Last) in '0' .. '9' then
               Last := Last - 1;

            else
               Ok_Maj := Last /= Last_Maj and then
               Maj_Version (Last) = '.';

               if Ok_Maj then
                  Last := Last - 1;
                  Ok_Maj :=
                    Maj_Version (Maj_Version'First .. Last) = Lib_Filename;
               end if;

               exit;
            end if;
         end loop;
      end if;

      if Ok_Maj then
         return Maj_Version (Maj_Version'First .. Last_Maj);
      else
         return "";
      end if;
   end Major_Id_Name;

   ------------------
   -- Partial_Name --
   ------------------

   function Partial_Name
     (Lib_Name      : String;
      Number        : Natural;
      Object_Suffix : String) return String
   is
      Img : constant String := Number'Img;
   begin
      return
        Partial_Prefix & Lib_Name &
        '_' & Img (Img'First + 1 .. Img'Last)
        & Object_Suffix;
   end Partial_Name;

   ------------------------
   -- Put_Resource_Usage --
   ------------------------

   procedure Put_Resource_Usage (Filename : String) is separate;

   --------------------------------
   -- Project_Compilation_Failed --
   --------------------------------

   function Project_Compilation_Failed
     (Prj       : Project_Id;
      Recursive : Boolean := True) return Boolean
   is
      use Project_Name_Boolean_Htable;
   begin
      if Get (Project_Failure, Prj.Name) then
         return True;

      elsif not Recursive then
         return False;

      else
         --  Check all imported projects directly or indirectly
         declare
            Plist : Project_List := Prj.All_Imported_Projects;
         begin
            while Plist /= null loop
               if Get (Project_Failure, Plist.Project.Name) then
                  return True;
               else
                  Plist := Plist.Next;
               end if;
            end loop;
            return False;
         end;
      end if;
   end Project_Compilation_Failed;

   -----------------------------------
   -- Set_Failed_Compilation_Status --
   -----------------------------------

   procedure Set_Failed_Compilation_Status (Prj : Project_Id) is
   begin
      Project_Name_Boolean_Htable.Set (Project_Failure, Prj.Name, True);
   end Set_Failed_Compilation_Status;

   -----------------------
   -- Shared_Libgcc_Dir --
   -----------------------

   function Shared_Libgcc_Dir (Run_Time_Dir : String) return String is
      Path      : String (1 .. Run_Time_Dir'Length + 15);
      Path_Last : constant Natural := Run_Time_Dir'Length;
      GCC_Index : Natural := 0;

   begin
      Path (1 .. Path_Last) := Run_Time_Dir;
      GCC_Index := Index (Path (1 .. Path_Last), "gcc-lib");

      if GCC_Index /= 0 then
         --  This is gcc 2.8.2: the shared version of libgcc is
         --  located in the parent directory of "gcc-lib".

         GCC_Index := GCC_Index - 1;

      else
         GCC_Index := Index (Path (1 .. Path_Last), "/lib/");

         if GCC_Index = 0 then
            GCC_Index :=
              Index
                (Path (1 .. Path_Last),
                 Directory_Separator & "lib" & Directory_Separator);
         end if;

         if GCC_Index /= 0 then
            --  We have found "lib" as a subdirectory in the runtime dir path.
            --  The
            declare
               Subdir : constant String :=
                 Interfaces.C.Strings.Value (Libgcc_Subdir_Ptr);
            begin
               Path
                 (GCC_Index + 1 ..
                    GCC_Index + Subdir'Length) :=
                   Subdir;
               GCC_Index :=
                 GCC_Index + Subdir'Length;
            end;
         end if;
      end if;

      return Path (1 .. GCC_Index);
   end Shared_Libgcc_Dir;

   ---------------------
   -- Need_To_Compile --
   ---------------------

   procedure Need_To_Compile
     (Source         : GPR.Source_Id;
      Tree           : Project_Tree_Ref;
      In_Project     : Project_Id;
      Conf_Paths     : Config_Paths;
      Must_Compile   : out Boolean;
      The_ALI        : out ALI.ALI_Id;
      Object_Check   : Boolean;
      Always_Compile : Boolean)
   is
      Source_Path         : constant String :=
                              Get_Name_String (Source.Path.Display_Name);
      C_Source_Path       : constant String :=
                              Get_Name_String (Source.Path.Name);
      Runtime_Source_Dirs : constant Name_List_Index :=
                             Source.Language.Config.Runtime_Source_Dirs;

      Stamp : Time_Stamp_Type;

      Source_In_Dependencies : Boolean := False;
      --  Set True if source was found in dependency file of its object file

      C_Object_Name : String_Access := null;
      --  The canonical file name for the object file

      Switches_Name : String_Access := null;
      --  The file name of the file that contains the switches that were used
      --  in the last compilation.

      Num_Ext : Natural;
      --  Number of extending projects

      ALI_Project : Project_Id;
      --  If the ALI file is in the object directory of a project, this is
      --  the project id.

      Externally_Built : constant Boolean := In_Project.Externally_Built;
      --  True if the project of the source is externally built

      Processed : Name_Id_Set.Set;
      --  Source files processed for ALI_Closure mode

      function Process_Makefile_Deps
        (Dep_Name, Obj_Dir : String) return Boolean;
      function Process_ALI_Deps
        (Source : Source_Id; Closure : Boolean) return Boolean;
      --  Process the dependencies for the current source file for the various
      --  dependency modes.
      --  They return True if the file needs to be recompiled.

      procedure Cleanup;
      --  Cleanup local variables

      function Check_Object_File (Source : Source_Id) return Boolean;
      --  Check object file exists and consistent with source file

      function Check_Time_Stamps
        (Path : String; Stamp : Time_Stamp_Type) return Boolean;

      -----------------------
      -- Check_Object_File --
      -----------------------

      function Check_Object_File (Source : Source_Id) return Boolean is
         function Obj_Path return String is
           (Get_Name_String (Source.Object_Path));
      begin
         --  If object file does not exist, of course source needs to be
         --  compiled.

         if Source.Object_TS = Empty_Time_Stamp then
            Source.Object_TS := File_Stamp (Obj_Path);
         end if;

         if Source.Object_TS = Empty_Time_Stamp then
            if Opt.Verbosity_Level > Opt.Low then
               Put ("      -> object file ");
               Put (Obj_Path);
               Put_Line (" does not exist");
            end if;

            return False;
         end if;

         --  If the object file has been created before the last modification
         --  of the source, the source needs to be recompiled.

         if not Opt.Minimal_Recompilation
           and then Source.Object_TS < Source.Source_TS
         then
            if Opt.Verbosity_Level > Opt.Low then
               Put  ("      -> object file ");
               Put  (Obj_Path);
               Put_Line (" has time stamp earlier than source");
            end if;

            return False;
         end if;

         if Opt.Verbosity_Level > Opt.Low and then Debug.Debug_Flag_T then
            Put ("   object file ");
            Put (Obj_Path);
            Put (": ");
            Put_Line (String (Source.Object_TS));

            Put ("   source file: ");
            Put_Line (String (Source.Source_TS));
         end if;

         return True;
      end Check_Object_File;

      -----------------------
      -- Check_Time_Stamps --
      -----------------------

      function Check_Time_Stamps
        (Path : String; Stamp : Time_Stamp_Type) return Boolean
      is
         TS : constant Time_Stamp_Type := File_Stamp (Get_Path_Name_Id (Path));
      begin
         if TS /= Empty_Time_Stamp and then TS /= Stamp then
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line ("   -> different time stamp for " & Path);

               if Debug.Debug_Flag_T then
                  Put_Line ("   in ALI file: " & String (Stamp));
                  Put_Line ("   actual file: " & String (TS));
               end if;
            end if;

            return True;
         end if;

         return False;
      end Check_Time_Stamps;

      ---------------------------
      -- Process_Makefile_Deps --
      ---------------------------

      function Process_Makefile_Deps
        (Dep_Name, Obj_Dir : String) return Boolean
      is
         Dep_File    : GPR.Util.Text_File;
         Last_Source : String_Access;
         Last_TS     : Time_Stamp_Type := Empty_Time_Stamp;
         Last_Obj    : Natural;
         Start       : Natural;
         Finish      : Natural;
         Looping     : Boolean := False;
         --  Set to True at the end of the first Big_Loop for Makefile
         --  fragments

         function Is_Time_Stamp (S : String) return Boolean;
         --  Return True iff S has the format of a Time_Stamp_Type

         OK : Boolean;

         -------------------
         -- Is_Time_Stamp --
         -------------------

         function Is_Time_Stamp (S : String) return Boolean is
            Result : Boolean := False;
         begin
            if S'Length = Time_Stamp_Length then
               Result := True;

               for J in S'Range loop
                  if S (J) not in '0' .. '9' then
                     Result := False;
                     exit;
                  end if;
               end loop;
            end if;

            return Result;
         end Is_Time_Stamp;

      begin
         Open (Dep_File, Dep_Name);

         --  If dependency file cannot be open, we need to recompile
         --  the source.

         if not Is_Valid (Dep_File) then
            if Opt.Verbosity_Level > Opt.Low then
               Put  ("      -> could not open dependency file ");
               Put_Line (Dep_Name);
            end if;

            return True;
         end if;

         --  Loop Big_Loop is executed several times only when the
         --  dependency file contains several times
         --     <object file>: <source1> ...
         --  When there is only one of such occurence, Big_Loop is exited
         --  successfully at the beginning of the second loop.

         Big_Loop :
         loop
            declare
               End_Of_File_Reached : Boolean := False;

            begin
               Skip_Loop :
               loop
                  if End_Of_File (Dep_File) then
                     End_Of_File_Reached := True;
                     exit Skip_Loop;
                  end if;

                  Get_Line (Dep_File, Name_Buffer, Name_Len);

                  if Name_Len > 0 and then Name_Buffer (1) /= '#' then
                     --  Skip a first line that is an empty continuation line

                     for J in 1 .. Name_Len - 1 loop
                        exit Skip_Loop when Name_Buffer (J) /= ' ';
                     end loop;

                     exit Skip_Loop when Name_Buffer (Name_Len) /= '\';
                  end if;
               end loop Skip_Loop;

               --  If dependency file contains only empty lines or comments,
               --  then dependencies are unknown, and the source needs to be
               --  recompiled.

               if End_Of_File_Reached then
                  --  If we have reached the end of file after the first
                  --  loop, there is nothing else to do.

                  exit Big_Loop when Looping;

                  if Opt.Verbosity_Level > Opt.Low then
                     Put  ("      -> dependency file ");
                     Put  (Dep_Name);
                     Put_Line (" is empty");
                  end if;

                  Close (Dep_File);
                  return True;
               end if;
            end;

            Start  := 1;
            Finish := Index (Name_Buffer (1 .. Name_Len), ": ");

            if Finish = 0 then
               Finish :=
                 Index
                   (Name_Buffer (1 .. Name_Len), (1 => ':', 2 => ASCII.HT));
            end if;

            if Finish /= 0 then
               Last_Obj := Finish;
               loop
                  Last_Obj := Last_Obj - 1;
                  exit when Last_Obj = Start
                    or else Name_Buffer (Last_Obj) /= ' ';
               end loop;

               while Start < Last_Obj and then Name_Buffer (Start) = ' ' loop
                  Start := Start + 1;
               end loop;

               Canonical_Case_File_Name (Name_Buffer (Start .. Last_Obj));
            end if;

            --  First line must start with simple name or path name of object
            --  file, followed by colon.

            if Finish = 0 then
               OK := False;

            else
               OK := C_Object_Name = null or else
                     Name_Buffer (Start .. Last_Obj) = C_Object_Name.all;

               if not OK then
                  declare
                     Path : String := Name_Buffer (Start .. Last_Obj);
                  begin
                     Canonical_Case_File_Name (Path);
                     OK := Path = Get_Name_String (Source.Object_Path);
                  end;
               end if;
            end if;

            if not OK then
               if Opt.Verbosity_Level > Opt.Low then
                  Put  ("      -> dependency file ");
                  Put  (Dep_Name);
                  Put_Line (" has wrong format");

                  if Finish = 0 then
                     Put_Line ("         no colon");

                  else
                     Put  ("         expected object file name ");
                     Put  (C_Object_Name.all);
                     Put  (", got ");
                     Put_Line (Name_Buffer (Start .. Last_Obj));
                  end if;
               end if;

               Close (Dep_File);
               return True;

            else
               Start := Finish + 2;

               --  Process each line

               Line_Loop : loop
                  declare
                     Line : String  := Name_Buffer (1 .. Name_Len);
                     Last : Natural := Name_Len;

                  begin
                     Name_Loop : loop

                        --  Find the beginning of the next source path name

                        while Start <= Last and then Line (Start) = ' ' loop
                           Start := Start + 1;
                        end loop;

                        exit Line_Loop when Start > Last;

                        --  Go to next line when there is a continuation
                        --  character \ at the end of the line.

                        exit Name_Loop when Start = Last
                          and then Line (Start) = '\';

                        --  We should not be at the end of the line, without
                        --  a continuation character \.

                        if Start = Last then
                           if Opt.Verbosity_Level > Opt.Low then
                              Put  ("      -> dependency file ");
                              Put  (Dep_Name);
                              Put_Line (" has wrong format");
                           end if;

                           Close (Dep_File);
                           return True;
                        end if;

                        --  Look for the end of the source path name

                        Finish := Start;

                        while Finish < Last loop
                           if Line (Finish) = '\' then
                              --  On Windows, a '\' is part of the path name,
                              --  except when it is not the first character
                              --  followed by another '\' or by a space.
                              --  On other platforms, when we are getting a '\'
                              --  that is not the last character of the line,
                              --  the next character is part of the path name,
                              --  even if it is a space.

                              if On_Windows
                                and then Finish = Start
                                and then Line (Finish + 1) = '\'
                              then
                                 Finish := Finish + 2;

                                 if Finish > Last then
                                    if Opt.Verbosity_Level > Opt.Low then
                                       Put  ("      -> dependency file ");
                                       Put  (Dep_Name);
                                       Put_Line (" has wrong format");
                                    end if;

                                    Close (Dep_File);
                                    return True;
                                 end if;

                              elsif On_Windows
                                and then Line (Finish + 1) not in '\' | ' '
                              then
                                 Finish := Finish + 1;

                              else
                                 Line (Finish .. Last - 1) :=
                                   Line (Finish + 1 .. Last);
                                 Last := Last - 1;
                              end if;

                           else
                              --  A space that is not preceded by '\'
                              --  indicates the end of the path name.

                              exit when Line (Finish + 1) = ' ';
                              Finish := Finish + 1;
                           end if;
                        end loop;

                        if Last_Source /= null
                          and then Is_Time_Stamp (Line (Start .. Finish))
                        then
                           --  If we have a time stamp, check if it is the
                           --  same as the source time stamp.

                           if String (Last_TS) = Line (Start .. Finish) then
                              Free (Last_Source);
                           else
                              if Opt.Verbosity_Level > Opt.Low then
                                 Put ("      -> source ");
                                 Put (Last_Source.all);
                                 Put_Line (" has modified time stamp");
                              end if;

                              Free (Last_Source);

                              Close (Dep_File);
                              return True;
                           end if;

                        else
                           --  Check this source

                           declare
                              Src_Name : constant String :=
                                Normalize_Pathname
                                  (Unescape (Line (Start .. Finish)),
                                   Directory      => Obj_Dir,
                                   Resolve_Links  => False);
                              C_Src_Name : String := Src_Name;
                              Src_TS   : Time_Stamp_Type;
                              Source_2 : GPR.Source_Id;

                           begin
                              Canonical_Case_File_Name (C_Src_Name);

                              --  If it is original source, set
                              --  Source_In_Dependencies.

                              if C_Src_Name = C_Source_Path then
                                 Source_In_Dependencies := True;
                              end if;

                              --  Get the time stamp of the source, which is
                              --  not necessarily a source of any project.

                              Src_TS := File_Stamp
                                (Get_Path_Name_Id (Src_Name));

                              --  If the source does not exist, we need to
                              --  recompile.

                              if Src_TS = Empty_Time_Stamp then
                                 if Opt.Verbosity_Level > Opt.Low then
                                    Put  ("      -> source ");
                                    Put  (Src_Name);
                                    Put_Line (" does not exist");
                                 end if;

                                 Close (Dep_File);
                                 return True;

                              --  If the source has been modified after the
                              --  object file, we need to recompile.

                              elsif Object_Check
                                and then
                                  Source.Language.Config.Object_Generated
                                and then Src_TS > Source.Object_TS
                              then
                                 if Opt.Verbosity_Level > Opt.Low then
                                    Put ("      -> source ");
                                    Put (Src_Name);
                                    Put_Line (" more recent than object file");
                                 end if;

                                 Close (Dep_File);
                                 return True;

                              else
                                 Source_2 := Source_Paths_Htable.Get
                                   (Tree.Source_Paths_HT,
                                    Get_Path_Name_Id (C_Src_Name));

                                 if Source_2 /= No_Source
                                   and then Source_2.Replaced_By /= No_Source
                                 then
                                    if Opt.Verbosity_Level > Opt.Low then
                                       Put ("      -> source ");
                                       Put (Src_Name);
                                       Put_Line (" has been replaced");
                                    end if;

                                    Close (Dep_File);
                                    return True;

                                 else
                                    Last_Source := new String'(Src_Name);
                                    Last_TS     := Src_TS;
                                 end if;
                              end if;
                           end;
                        end if;

                        --  If the source path name ends the line, we are
                        --  done.

                        exit Line_Loop when Finish = Last;

                        --  Go get the next source on the line

                        Start := Finish + 1;
                     end loop Name_Loop;
                  end;

                  --  If we are here, we had a continuation character \ at
                  --  the end of the line, so we continue with the next
                  --  line.

                  Get_Line (Dep_File, Name_Buffer, Name_Len);
                  Start  := 1;
                  Finish := 1;
               end loop Line_Loop;
            end if;

            --  Set Looping at the end of the first loop
            Looping := True;
         end loop Big_Loop;

         Close (Dep_File);

         --  If the original sources were not in the dependency file, then
         --  we need to recompile. It may mean that we are using a different
         --  source (different variant) for this object file.

         if not Source_In_Dependencies then
            if Opt.Verbosity_Level > Opt.Low then
               Put  ("      -> source ");
               Put  (Source_Path);
               Put_Line (" is not in the dependencies");
            end if;

            return True;
         end if;

         return False;
      end Process_Makefile_Deps;

      type Config_Paths_Found is array (Positive range <>) of Boolean;
      --  Type to record what config files are included in the ALI file

      ----------------------
      -- Process_ALI_Deps --
      ----------------------

      function Process_ALI_Deps
        (Source : Source_Id; Closure : Boolean) return Boolean
      is
         Text : Text_Buffer_Ptr :=
                  Read_Library_Info_From_Full
                    (File_Name_Type (Source.Dep_Path), Source.Dep_TS'Access);

         Proj  : Project_Id;
         Found : Boolean := False;
         Preps : String_Sets.Set;
         --  Preprocessor data files to detect config pragma files by exclusion
         --  method. If file in D line is absolute filename then it is either
         --  config pragma file or preprocessor data file. We can detect that
         --  the file is preprocessor data files by the existence of the A line
         --  with --  -gnatep= prefix. Config pragma files in D line does not
         --  have any additional references.

         Conf_Paths_Found : Config_Paths_Found := (Conf_Paths'Range => False);

         The_ALI : ALI_Id;

      begin
         if Text = null then
            if Opt.Verbosity_Level > Opt.Low then
               Put ("    -> cannot read ");
               Put_Line (Get_Name_String (Source.Dep_Path));
            end if;

            return True;
         end if;

         --  Read only the necessary lines of the ALI file

         The_ALI :=
           ALI.Scan_ALI
             (File_Name_Type (Source.Dep_Path),
              Text,
              Ignore_ED  => False,
              Err        => True,
              Read_Lines => "APDW");
         Free (Text);

         if Source = Need_To_Compile.Source then
            Need_To_Compile.The_ALI := The_ALI;

         elsif Need_To_Compile.Stamp
           < File_Time_Stamp (Source.Dep_Path, Source.Dep_TS'Access)
         then
            --  We can be here only in Closure mode because
            --  Source /= Need_To_Compile.Source
            --  see if condition.

            if Opt.Verbosity_Level > Opt.Low then
               Put ("    -> ALI file from dependencies ");
               Put (Get_Name_String (Source.Dep_Name));
               Put (" later than ");
               Put_Line (Get_Name_String (Need_To_Compile.Source.Dep_Name));
            end if;

            return True;

         elsif Object_Check then
            Initialize_Source_Record (Source);

            if not Check_Object_File (Source) then
               return True;
            end if;
         end if;

         if The_ALI = ALI.No_ALI_Id then
            if Opt.Verbosity_Level > Opt.Low then
               Put ("    -> ");
               Put (Get_Name_String (Source.Dep_Path));
               Put_Line (" is incorrectly formatted");
            end if;

            return True;
         end if;

         declare
            U : Unit_Record renames Units.Table
              (ALIs.Table (The_ALI).First_Unit);
            A : String_Access;

            Gnatep : constant String := "-gnatep=";
            File   : Text_File;

            procedure Prep_Append (Filename : String);

            -----------------
            -- Prep_Append --
            -----------------

            procedure Prep_Append (Filename : String) is
            begin
               Preps.Include
                 (Normalize_Pathname (Filename, Case_Sensitive => False));
            end Prep_Append;

         begin
            for J in U.First_Arg .. U.Last_Arg loop
               A := Args.Table (J);
               if Starts_With (A.all, Gnatep) then
                  Prep_Append (A (A'First + Gnatep'Length .. A'Last));

                  --  Extract all definition filenames from preprocessor data
                  --  file. Put it into the Preps too.

                  Open (File, A (A'First + Gnatep'Length .. A'Last));

                  while Is_Valid (File) and then not End_Of_File (File) loop
                     declare
                        Line   : constant String := Get_Line (File);
                        Str    : String (Line'Range);
                        Last   : Natural;
                        Scan   : Positive := Line'First;

                        procedure Scan_String_Literal;
                        --  Scan string literal from Line starting from Scan
                        --  index.

                        -------------------------
                        -- Scan_String_Literal --
                        -------------------------

                        procedure Scan_String_Literal is
                           Was_DQ : Boolean := False;
                           Inside : Boolean := False;
                        begin
                           Last := Str'First - 1;

                           for Idx in Scan .. Line'Last loop
                              if Line (Idx) = '"' then
                                 if Inside then
                                    if Was_DQ then
                                       Last := Last + 1;
                                       Str (Last) := '"';
                                    end if;

                                    Was_DQ := not Was_DQ;

                                 else
                                    Inside := True;
                                 end if;

                              else
                                 if Was_DQ then
                                    Scan := Idx;
                                    exit;
                                 end if;

                                 if Inside then
                                    Last := Last + 1;
                                    Str (Last) := Line (Idx);
                                 end if;
                              end if;
                           end loop;
                        end Scan_String_Literal;

                     begin
                        if Line /= "" then
                           case Line (Line'First) is
                              when '*' =>
                                 Scan_String_Literal;
                                 Prep_Append (Str (Str'First .. Last));
                              when '"' =>
                                 Scan_String_Literal;
                                 Scan_String_Literal;
                                 Prep_Append (Str (Str'First .. Last));
                              when others =>
                                 null;
                           end case;
                        end if;
                     end;
                  end loop;

                  if Is_Valid (File) then
                     Close (File);
                  end if;
               end if;
            end loop;
         end;

         --  Check if the ALI's GNAT version matches
         --  Tree.Shared.Ada_Runtime_Library_Version

         declare
            GNAT_Version : constant Name_Id :=
              ALI.ALIs.Table (The_ALI).GNAT_Version;
         begin
            if GNAT_Version /= Tree.Shared.Ada_Runtime_Library_Version then
               if Opt.Verbosity_Level > Opt.Low then
                  Put ("    -> GNAT version changed: ");
                  Put ("ALI version = ");
                  Put (Get_Name_String (GNAT_Version));
                  Put ("; expected version = ");

                  if Tree.Shared.Ada_Runtime_Library_Version /= No_Name then
                     Put_Line
                       (Get_Name_String
                         (Tree.Shared.Ada_Runtime_Library_Version));
                  else
                     Put_Line ("unknown");
                  end if;
               end if;

               return True;
            end if;
         end;

         if ALI.ALIs.Table (The_ALI).Compile_Errors then
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line ("    -> last compilation had errors");
            end if;

            return True;
         end if;

         if Object_Check and then ALI.ALIs.Table (The_ALI).No_Object then
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line
                 ("    -> no object generated during last compilation");
            end if;

            return True;
         end if;

         if Check_Source_Info_In_ALI (The_ALI, Tree) = No_Name then
            return True;
         end if;

         --  We need to check that the ALI file is in the correct object
         --  directory. If it is in the object directory of a project
         --  that is extended and it depends on a source that is in one
         --  of its extending projects, then the ALI file is not in the
         --  correct object directory.

         ALI_Project := Source.Object_Project;

         --  Count the extending projects

         Num_Ext := 0;
         Proj := ALI_Project;
         loop
            Proj := Proj.Extended_By;
            exit when Proj = No_Project;
            Num_Ext := Num_Ext + 1;
         end loop;

         declare
            Projects : array (1 .. Num_Ext) of Project_Id;
            Sfile    : File_Name_Type;
            Dep_Src  : GPR.Source_Id;
            Position : Name_Id_Set.Cursor;
            Inserted : Boolean;
            ALI_Rec  : ALIs_Record renames ALI.ALIs.Table (The_ALI);
         begin
            Proj := ALI_Project;
            for J in Projects'Range loop
               Proj := Proj.Extended_By;
               Projects (J) := Proj;
            end loop;

            for D in ALI_Rec.First_Sdep .. ALI_Rec.Last_Sdep loop
               Sfile := ALI.Sdep.Table (D).Sfile;
               Dep_Src := Source_Files_Htable.Get
                            (Tree.Source_Files_HT, Sfile);

               if Closure and then Dep_Src /= No_Source then
                  Processed.Insert (Name_Id (Sfile), Position, Inserted);
               else
                  Inserted := True;
               end if;

               if Inserted
                 and then ALI.Sdep.Table (D).Stamp /= Empty_Time_Stamp
               then
                  Found := False;

                  if Dep_Src = No_Source
                    and then ALI.Sdep.Table (D).Checksum = 0
                  then
                     --  Probably preprocessing dependencies. Look for the
                     --  file in the directory of the source, then the other
                     --  source directories of the project.

                     declare
                        Path  : Path_Name_Type   := No_Path;
                        File  : constant String  := Get_Name_String (Sfile);
                        Stamp : Time_Stamp_Type  := Empty_Time_Stamp;
                        List  : String_List_Id   := In_Project.Source_Dirs;
                        Absp  : constant Boolean := Is_Absolute_Path (File);
                        --  Config pragma file or preprocessor data file
                        Elem  : String_Element;

                        procedure Get_Path (Dir : String);
                        --  If File is in the absolute directory Dir then
                        --  set Path to the absolute path of the file and
                        --  Stamp to its timestamp. Otherwise Path is
                        --  No_Path.

                        --------------
                        -- Get_Path --
                        --------------

                        procedure Get_Path (Dir : String) is
                        begin
                           Set_Name_Buffer (Dir);
                           Add_Char_To_Name_Buffer (Directory_Separator);
                           Add_Str_To_Name_Buffer (File);
                           Path := Name_Find;

                           Stamp := File_Stamp (Path);

                           if Stamp = Empty_Time_Stamp then
                              Path := No_Path;
                           end if;
                        end Get_Path;

                     begin

                        if Conf_Paths'Length > 0 or else Absp then
                           Path := Path_Name_Type (Sfile);
                           Stamp := File_Stamp (Path);

                           declare
                              Found     : Boolean := False;
                              Norm_Path : constant String :=
                                            Normalize_Pathname
                                              (File,
                                               Case_Sensitive => False);
                           begin
                              for J in Conf_Paths'Range loop
                                 if Conf_Paths (J).Name = Get_Path_Name_Id
                                   (Norm_Path)
                                 then
                                    Found                := True;
                                    Conf_Paths_Found (J) := True;
                                 end if;
                              end loop;

                              if Absp
                                and then not Found
                                and then not Preps.Contains (Norm_Path)
                              then
                                 --  Config pragma file is in D line but was
                                 --  not referenced from project and
                                 --  -gnatec = command line option.

                                 if Opt.Verbosity_Level > Opt.Low then
                                    Put ("  -> """);
                                    Put (File);
                                    Put_Line
                                      (""" not defined in project and "
                                       & "-gnatec= command line option");

                                    if Opt.Verbosity_Level > Opt.Medium then
                                       Put ("Warning: Dependency file """);
                                       Put (Get_Name_String (Source.Dep_Path));
                                       Put_Line
                                         (""" contains outdated information "
                                          & "about configuration file. ");
                                       Put_Line
                                         ("Warning: Consider using the "
                                          & "-gnateb switch if supported by "
                                          & "the compiler.");
                                    end if;
                                 end if;

                                 return True;
                              end if;
                           end;
                        end if;

                        --  Look in the directory of the source

                        if Path = No_Path then
                           Get_Path (Source_Dir_Of (Source));
                        end if;

                        while Path = No_Path and then List /= Nil_String
                        loop
                           Elem := Tree.Shared.String_Elements.Table (List);
                           Get_Path (Get_Name_String (Elem.Display_Value));
                           List := Elem.Next;
                        end loop;

                        if Stamp /= ALI.Sdep.Table (D).Stamp then
                           if Opt.Verbosity_Level > Opt.Low then
                              if Stamp = Empty_Time_Stamp then
                                 Put ("  -> """);
                                 Put (Get_Name_String (Sfile));
                                 Put_Line (""" missing");

                              else
                                 Put ("   -> different time stamp for ");
                                 Put_Line (Get_Name_String (Path));

                                 if Debug.Debug_Flag_T then
                                    Put ("   in ALI file: ");
                                    Put_Line
                                      (String (ALI.Sdep.Table (D).Stamp));
                                    Put ("   actual file: ");
                                    Put_Line (String (Stamp));
                                 end if;
                              end if;
                           end if;

                           return True;
                        end if;
                     end;

                  else

                     if Dep_Src = No_Source
                       and then not Is_Ada_Predefined_File_Name (Sfile)
                       and then not Is_Pragmas_Config_File (Sfile)
                     then
                        if Opt.Verbosity_Level > Opt.Low then
                           Put ("  -> """);
                           Put (Get_Name_String (Sfile));
                           Put_Line (""" missing");
                        end if;

                        return True;
                     end if;

                     if Dep_Src = No_Source
                       and then Is_Pragmas_Config_File (Sfile)
                     then
                        declare
                           F_And_Cksum_Found : Boolean := False;
                           Timestamp_Found   : Boolean := False;
                        begin
                           for J in Conf_Paths'Range loop
                              declare
                                 File   : constant File_Name_Type :=
                                            Get_File_Name_Id
                                              (Ada.Directories.Simple_Name
                                                 (Get_Name_String
                                                    (Conf_Paths (J).Name)));
                                 Cksum  : Word;
                                 SCksum : constant Word :=
                                            ALI.Sdep.Table (D).Checksum;
                              begin
                                 Cksum := Calculate_Checksum
                                   (Conf_Paths (J).Name);

                                 if File = Sfile
                                   and then
                                     Cksum = SCksum
                                     and then not Conf_Paths_Found (J)
                                 then
                                    F_And_Cksum_Found := True;

                                    if File_Stamp (Conf_Paths (J).Name) =
                                      ALI.Sdep.Table (D).Stamp
                                    then
                                       Conf_Paths_Found (J) := True;
                                       Timestamp_Found      := True;
                                       exit;
                                    end if;
                                 end if;
                              end;
                           end loop;

                           --  If the file is missing from our internal config
                           --  file list, recompute the config file checksum
                           --  from the * .ali file and compare it.
                           --  This prevents total project recompilation if
                           --  --gnatec is declared at Compiler package
                           --  switches level.
                           if not F_And_Cksum_Found then
                              if Calculate_Checksum
                                (File => Path_Name_Type (Sfile)) =
                                  ALI.Sdep.Table (D).Checksum
                              then
                                 F_And_Cksum_Found := True;
                                 if File_Stamp (Path_Name_Type (Sfile)) =
                                   ALI.Sdep.Table (D).Stamp
                                 then
                                    Timestamp_Found := True;
                                 end if;
                              end if;
                           end if;

                           if not F_And_Cksum_Found then
                              --  Config pragma file is in D line but was
                              --  not referenced from project and
                              --  -gnatec= command line option.

                              if Opt.Verbosity_Level > Opt.Low then
                                 Put ("  -> """);
                                 Put (Get_Name_String (Sfile));
                                 Put_Line
                                   (""" not defined in project and "
                                    & "-gnatec= command line option");
                              end if;

                              return True;
                           end if;

                           if not Timestamp_Found then
                              if Opt.Verbosity_Level > Opt.Low then
                                 Put ("   -> different time stamp from the "
                                      & "ALI file for the config file ");
                                 Put_Line (Get_Name_String (Sfile));
                              end if;

                              return True;
                           end if;
                        end;
                     end if;

                     while Dep_Src /= No_Source loop
                        if not Dep_Src.Locally_Removed
                          and then Dep_Src.Unit /= No_Unit_Index
                        then
                           Found := True;

                           Initialize_Source_Record (Dep_Src);

                           if Dep_Src.Checksum /= ALI.Sdep.Table (D).Checksum
                           then
                              --  Checksum saved in source file differ from
                              --  ALI D line checksum.

                              case Dep_Src.Checksum_Src is
                                 when No_File =>
                                    --  Checksum was not saved. Save it.

                                    Dep_Src.Checksum_Src := Source.File;
                                    Dep_Src.Checksum :=
                                      ALI.Sdep.Table (D).Checksum;

                                 when True_Checksum =>
                                    --  Checksum calculated from file and D
                                    --  record from ALI does not fit it. We
                                    --  have to rebuild source.

                                    return True;

                                 when others =>
                                    if Dep_Src.File = Dep_Src.Checksum_Src then
                                       --  The checksum saved from the D record
                                       --  of the source itself. It is more
                                       --  reliable than the D line of the
                                       --  other sources. Rebuild the source.

                                       return True;
                                    end if;

                                    --  If we have 2 different sources with D
                                    --  lines referenced to the Dep_Src with
                                    --  different checksum, we should calculate
                                    --  checksum from source file.

                                    declare
                                       Prev_Src : constant File_Name_Type :=
                                                    Dep_Src.Checksum_Src;
                                       Prev_Chs : constant Word :=
                                                    Dep_Src.Checksum;
                                       Prev_Sid : Source_Id;
                                       Success  : Boolean;
                                    begin
                                       if Calculate_Checksum (Dep_Src) then
                                          if Dep_Src.Checksum /= Prev_Chs then
                                             --  Saved D line checksum from
                                             --  previos source was wrond. We
                                             --  have to rebuild previous
                                             --  source file.

                                             Prev_Sid :=
                                               Source_Files_Htable.Get
                                                 (Tree.Source_Files_HT,
                                                  Prev_Src);

                                             --  Delete obsolete ALI file if
                                             --  exists.

                                             Delete_File
                                               (Get_Name_String
                                                  (Prev_Sid.Dep_Path),
                                                Success);

                                             --  Insert the source into the
                                             --  queue again.

                                             Queue.Insert
                                               (Source =>
                                                  (Tree, Prev_Sid,
                                                   Closure => True),
                                                With_Roots => True,
                                                Repeat     => True);
                                          end if;

                                          if Dep_Src.Checksum
                                            /= ALI.Sdep.Table (D).Checksum
                                          then
                                             --  If calculated checksum differ
                                             --  from D line checksum, we have
                                             --  to compile this Source.

                                             return True;
                                          end if;
                                       end if;
                                    end;
                              end case;
                           end if;

                           if (Opt.Minimal_Recompilation
                               and then ALI.Sdep.Table (D).Stamp
                                        /= Dep_Src.Source_TS)
                             or else
                             (ALI.Sdep.Table (D).Stamp = Dep_Src.Source_TS
                              and then Opt.Checksum_Recompilation)
                           then
                              --  If minimal recompilation is in action,
                              --  replace the stamp of the source file in
                              --  the table if checksums match.

                              if Calculate_Checksum (Dep_Src) then
                                 if Dep_Src.Checksum
                                    = ALI.Sdep.Table (D).Checksum
                                 then
                                    if Opt.Verbosity_Level > Opt.Low then
                                       Put ("   ");
                                       Put
                                         (Get_Name_String
                                            (ALI.Sdep.Table (D).Sfile));
                                       Put (": up to date, " &
                                              "different timestamps " &
                                              "but same checksum");
                                       New_Line;
                                    end if;

                                    ALI.Sdep.Table (D).Stamp :=
                                      Dep_Src.Source_TS;

                                 elsif Opt.Checksum_Recompilation then
                                    if Opt.Verbosity_Level > Opt.Low then
                                       Put ("   ");
                                       Put
                                         (Get_Name_String
                                            (ALI.Sdep.Table (D).Sfile));
                                       Put_Line
                                         (": changed, same timestamp but"
                                          & " different checksums");
                                    end if;

                                    return True;
                                 end if;
                              end if;
                           end if;

                           if ALI.Sdep.Table (D).Stamp /= Dep_Src.Source_TS
                           then
                              if Opt.Verbosity_Level > Opt.Low then
                                 Put
                                   ("   -> different time stamp for ");
                                 Put_Line (Get_Name_String (Sfile));

                                 if Debug.Debug_Flag_T then
                                    Put ("   in ALI file: ");
                                    Put_Line
                                      (String (ALI.Sdep.Table (D).Stamp));
                                    Put ("   actual file: ");
                                    Put_Line (String (Dep_Src.Source_TS));
                                 end if;
                              end if;

                              return True;
                           end if;

                           for J in Projects'Range loop
                              if Dep_Src.Project = Projects (J) then
                                 if Opt.Verbosity_Level > Opt.Low then
                                    Put_Line
                                      ("   -> dependency file not in " &
                                         "object directory of project """ &
                                         Get_Name_String
                                         (Projects
                                              (Projects'Last).Display_Name) &
                                         """");
                                 end if;

                                 return True;
                              end if;
                           end loop;

                           if Closure
                             and then Dep_Src /= Source
                             and then Dep_Src.Kind /= Sep
                             and then not Dep_Src.Project.Externally_Built
                             and then Process_ALI_Deps (Dep_Src, True)
                           then
                              return True;
                           end if;

                           exit;
                        end if;

                        Dep_Src := Dep_Src.Next_With_File_Name;
                     end loop;

                     --  If the source was not found and the runtime source
                     --  directory is defined, check if the file exists there,
                     --  and if it does, check its timestamp.

                     if not Found
                       and then
                         (Runtime_Source_Dirs /= No_Name_List
                          or else
                          Is_Absolute_Path (Get_Name_String (Sfile)))
                     then
                        if Is_Absolute_Path (Get_Name_String (Sfile)) then
                           if Check_Time_Stamps
                             (Get_Name_String (Sfile),
                              ALI.Sdep.Table (D).Stamp)
                           then
                              return True;
                           end if;

                        else
                           declare
                              R_Dirs : Name_List_Index := Runtime_Source_Dirs;
                           begin
                              while R_Dirs /= No_Name_List loop
                                 declare
                                    Nam_Nod : constant Name_Node :=
                                      Tree.Shared.Name_Lists.Table (R_Dirs);
                                 begin
                                    if Check_Time_Stamps
                                      (Get_Name_String (Nam_Nod.Name) &
                                         Directory_Separator &
                                         Get_Name_String (Sfile),
                                       ALI.Sdep.Table (D).Stamp)
                                    then
                                       return True;
                                    end if;

                                    R_Dirs := Nam_Nod.Next;
                                 end;
                              end loop;
                           end;
                        end if;
                     end if;
                  end if;
               end if;
            end loop;

            --  Check that all the config files have been found in the ALI file

            if Source.Language.Config.Config_File_Dependency_Support then
               for J in Conf_Paths_Found'Range loop
                  if not Conf_Paths_Found (J) then
                     if Opt.Verbosity_Level > Opt.Low then
                        Put_Line
                          ("   -> new config file " &
                             Get_Name_String (Conf_Paths (J).Display_Name));
                     end if;

                     return True;
                  end if;
               end loop;
            end if;
         end;

         return False;
      end Process_ALI_Deps;

      -------------
      -- Cleanup --
      -------------

      procedure Cleanup is
      begin
         Free (C_Object_Name);
         Free (Switches_Name);
      end Cleanup;

   begin
      The_ALI := ALI.No_ALI_Id;

      --  Never attempt to compile header files

      if Source.Language.Config.Kind = File_Based
        and then Source.Kind = Spec
      then
         Must_Compile := False;
         return;
      end if;

      if Force_Compilations then
         Must_Compile := Always_Compile or else not Externally_Built;
         return;
      end if;

      --  Fail if no compiler

      if Source.Language.Config.Compiler_Driver = No_File then
         Fail_Program
           (Tree,
            "no compiler for """ & Get_Name_String (Source.File) & '"');
      end if;

      --  No need to compile if there is no "compiler"

      if Source.Language.Config.Compiler_Driver = Empty_File then
         Must_Compile := False;
         return;
      end if;

      if Source.Language.Config.Object_Generated and then Object_Check then
         C_Object_Name := new String'(Get_Name_String (Source.Object));
         Canonical_Case_File_Name (C_Object_Name.all);

         if Source.Switches_Path /= No_Path then
            Switches_Name :=
              new String'(Get_Name_String (Source.Switches_Path));
         end if;
      end if;

      if Opt.Verbosity_Level > Opt.Low then
         Put  ("   Checking ");
         Put  (Source_Path);

         if Source.Index /= 0 then
            Put (" at");
            Put (Source.Index'Img);
         end if;

         Put_Line (" ... ");
      end if;

      --  No need to compile if project is externally built

      if Externally_Built then
         if Opt.Verbosity_Level > Opt.Low then
            Put_Line ("      project is externally built");
         end if;

         Must_Compile := False;
         Cleanup;
         return;
      end if;

      if not Source.Language.Config.Object_Generated then
         --  If no object file is generated, the "compiler" need to be invoked
         --  if there is no dependency file.

         if Source.Language.Config.Dependency_Kind = None then
            if Opt.Verbosity_Level > Opt.Low then
               Put_Line ("      -> no object file generated");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

      elsif Object_Check and then not Check_Object_File (Source) then
         Must_Compile := True;
         Cleanup;
         return;
      end if;

      if Source.Language.Config.Dependency_Kind /= None then

         --  If there is no dependency file, then the source needs to be
         --  recompiled and the dependency file need to be created.

         Stamp := File_Time_Stamp (Source.Dep_Path, Source.Dep_TS'Access);

         if Stamp = Empty_Time_Stamp then
            if Opt.Verbosity_Level > Opt.Low then
               Put ("      -> dependency file ");
               Put (Get_Name_String (Source.Dep_Path));
               Put_Line (" does not exist");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

         if In_Project.Library
           and then Source.Unit /= No_Unit_Index
           and then Source.In_Interfaces
         then
            declare
               Dep_Path : constant String :=
                            Normalize_Pathname
                              (Get_Name_String (Source.Dep_Name),
                               Get_Name_String
                                 (In_Project.Library_ALI_Dir.Name),
                               Resolve_Links => Opt.Follow_Links_For_Files);
               Lib_Stamp : constant Time_Stamp_Type := File_Stamp (Dep_Path);
            begin
               if Lib_Stamp = Empty_Time_Stamp then
                  if Opt.Verbosity_Level > Opt.Low then
                     Put ("      -> file ");
                     Put (Dep_Path);
                     Put_Line (" does not exist");
                  end if;

                  In_Project.Need_Build := True;

               elsif Lib_Stamp < Stamp then
                  if Opt.Verbosity_Level > Opt.Low then
                     Put ("      -> file ");
                     Put (Dep_Path);
                     Put (" has timestamp earlier than ");
                     Put_Line (Get_Name_String (Source.Dep_Path));
                  end if;

                  In_Project.Need_Build := True;
               end if;
            end;
         end if;

         --  If the ALI file has been created after the object file, we need
         --  to recompile.

         if Object_Check
           and then Source.Language.Config.Dependency_Kind in ALI_Dependency
           and then Source.Object_TS < Stamp
         then
            if Opt.Verbosity_Level > Opt.Low then
               Put ("      -> ALI file ");
               Put (Get_Name_String (Source.Dep_Path));
               Put_Line (" has timestamp later than object file");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

         --  The source needs to be recompiled if the source has been modified
         --  after the dependency file has been created.

         if not Opt.Minimal_Recompilation
           and then Stamp < Source.Source_TS
         then
            if Opt.Verbosity_Level > Opt.Low then
               Put  ("      -> dependency file ");
               Put  (Get_Name_String (Source.Dep_Path));
               Put_Line (" has time stamp earlier than source");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;
      end if;

      --  If we are checking the switches and there is no switches file, then
      --  the source needs to be recompiled and the switches file need to be
      --  created.

      if Check_Switches and then Switches_Name /= null then
         if Source.Switches_TS = Empty_Time_Stamp then
            if Opt.Verbosity_Level > Opt.Low then
               Put  ("      -> switches file ");
               Put  (Switches_Name.all);
               Put_Line (" does not exist");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;

         --  The source needs to be recompiled if the source has been modified
         --  after the switches file has been created.

         if not Opt.Minimal_Recompilation
           and then Source.Switches_TS < Source.Source_TS
         then
            if Opt.Verbosity_Level > Opt.Low then
               Put  ("      -> switches file ");
               Put  (Switches_Name.all);
               Put_Line (" has time stamp earlier than source");
            end if;

            Must_Compile := True;
            Cleanup;
            return;
         end if;
      end if;

      case Source.Language.Config.Dependency_Kind is
         when None =>
            null;

         when Makefile =>
            if Process_Makefile_Deps
                 (Get_Name_String (Source.Dep_Path),
                  Get_Name_String
                    (Source.Project.Object_Directory.Display_Name))
            then
               Must_Compile := True;
               Cleanup;
               return;
            end if;

         when ALI_File =>
            if Process_ALI_Deps (Source, Closure => False) then
               Must_Compile := True;
               Cleanup;
               return;
            end if;

         when ALI_Closure =>
            if Process_ALI_Deps (Source, Closure => True) then
               Must_Compile := True;
               Cleanup;
               return;
            end if;
      end case;

      --  If we are here, then everything is OK, and we don't need
      --  to recompile.

      if not Object_Check and then Opt.Verbosity_Level > Opt.Low then
         Put_Line ("      -> up to date");
      end if;

      Must_Compile := False;
      Cleanup;
   end Need_To_Compile;

   ---------------------------
   -- Set_Default_Verbosity --
   ---------------------------

   procedure Set_Default_Verbosity is
      Gpr_Verbosity : String_Access := Getenv ("GPR_VERBOSITY");
   begin
      if Gpr_Verbosity /= null and then Gpr_Verbosity'Length > 0 then
         declare
            Verbosity : String := Gpr_Verbosity.all;
         begin
            To_Lower (Verbosity);

            if Verbosity = "quiet" then
               Quiet_Output    := True;
               Verbose_Mode    := False;
               Verbosity_Level := Opt.None;

            elsif Verbosity = "default" then
               Quiet_Output    := False;
               Verbose_Mode    := False;
               Verbosity_Level := Opt.None;

            elsif Verbosity = "verbose" or else Verbosity = "verbose_low" then
               Quiet_Output    := False;
               Verbose_Mode    := True;
               Verbosity_Level := Opt.Low;

            elsif Verbosity = "verbose_medium" then
               Quiet_Output    := False;
               Verbose_Mode    := True;
               Verbosity_Level := Opt.Medium;

            elsif Verbosity = "verbose_high" then
               Quiet_Output    := False;
               Verbose_Mode    := True;
               Verbosity_Level := Opt.High;
            end if;
         end;
      end if;

      Free (Gpr_Verbosity);
   end Set_Default_Verbosity;

   --------------------
   -- Set_Gprls_Mode --
   --------------------

   procedure Set_Gprls_Mode is
   begin
      Gprls_Mode := True;
   end Set_Gprls_Mode;

   ---------------
   -- Knowledge --
   ---------------

   package body Knowledge is separate;

   ----------------
   -- Check_Diff --
   ----------------

   function Check_Diff
     (Ts1, Ts2 : Time_Stamp_Type; Max_Drift : Duration := 5.0) return Boolean
   is
      use Ada.Calendar;

      function Get (T : String) return Time is
        (Time_Of
           (Year   => Year_Number'Value   (T (T'First .. T'First + 3)),
            Month  => Month_Number'Value  (T (T'First + 4 .. T'First + 5)),
            Day    => Day_Number'Value    (T (T'First + 6 .. T'First + 7)),
            Hour   => Hour_Number'Value   (T (T'First + 8 .. T'First + 9)),
            Minute => Minute_Number'Value (T (T'First + 10 .. T'First + 11)),
            Second => Second_Number'Value (T (T'First + 12 .. T'First + 13))));

      T1 : constant Time := Get (String (Ts1));
      T2 : constant Time := Get (String (Ts2));

   begin
      return abs (T1 - T2) <= Max_Drift;
   end Check_Diff;

   -----------------------------
   -- Check_Maximum_Processes --
   -----------------------------

   procedure Check_Maximum_Processes is

      Already_Reported : Boolean := False;

      procedure Check_It (Value : in out Positive);

      --------------
      -- Check_It --
      --------------

      procedure Check_It (Value : in out Positive) is
         Max_Proc : constant := 63;
      begin
         if Value > Max_Proc then
            Value := Max_Proc;

            if not Already_Reported then
               Already_Reported := True;
               Put_Line
                 ("On Windows the maximum number of simultaneous processes is"
                  & Max_Proc'Img);
            end if;
         end if;
      end Check_It;

   begin
      if On_Windows then
         Check_It (Opt.Maximum_Compilers);
         Check_It (Opt.Maximum_Binders);
         Check_It (Opt.Maximum_Linkers);
      end if;
   end Check_Maximum_Processes;

   --------------------
   -- Project_Output --
   --------------------

   package body Project_Output is

      ----------------
      -- Write_Char --
      ----------------

      procedure Write_A_Char (C : Character) is
      begin
         Write_A_String ((1 => C));
      end Write_A_Char;

      ---------------
      -- Write_Eol --
      ---------------

      procedure Write_Eol is
      begin
         Write_A_String ((1 => ASCII.LF));
      end Write_Eol;

      --------------------
      -- Write_A_String --
      --------------------

      procedure Write_A_String (S : String) is
         Str : String (1 .. S'Length);

      begin
         if S'Length > 0 then
            Str := S;

            if Write (Output_FD, Str (1)'Address, Str'Length) /= Str'Length
            then
               GPR.Com.Fail ("disk full");
            end if;
         end if;
      end Write_A_String;

   end Project_Output;

   ----------------------------
   -- Command Line Arguments --
   ----------------------------

   package Command_Line_Arguments is new GNAT.Table
     (Table_Component_Type => Name_Id,
      Table_Index_Type     => Natural,
      Table_Low_Bound      => 1,
      Table_Initial        => 10,
      Table_Increment      => 100);

   -----------------------------------
   -- Delete_Command_Line_Arguments --
   -----------------------------------

   procedure Delete_Command_Line_Arguments is
   begin
      Command_Line_Arguments.Set_Last (0);
   end Delete_Command_Line_Arguments;

   --------------------------------
   -- Get_Command_Line_Arguments --
   --------------------------------

   procedure Get_Command_Line_Arguments is
      File : File_Type;

      procedure Read_File (Name : String);
      --  Read argument file with name Name and put the arguments into table
      --  Command_Line_Arguments.

      ---------------
      -- Read_File --
      ---------------

      procedure Read_File (Name : String) is
      begin
         begin
            Open (File, In_File, Name);
         exception
            when others =>
               Fail_Program
                 (null, "could not open argument file """ & Name & '"',
                  Exit_Code => E_General);
         end;

         while not End_Of_File (File) loop
            Get_Line (File, Name_Buffer, Name_Len);

            if Name_Len /= 0 and then
              (Name_Len = 1 or else Name_Buffer (1 .. 2) /= "--")
            then
               if Name_Buffer (1) = '@' then
                  Fail_Program
                    (null,
                     "invalid argument """ & Name_Buffer (1 .. Name_Len)
                     & """ in argument file",
                     Exit_Code => E_General);

               else
                  Command_Line_Arguments.Append (Name_Find);
               end if;
            end if;
         end loop;

         Close (File);
      end Read_File;

   begin
      for J in 1 .. Argument_Count loop
         declare
            Arg : constant String := Argument (J);
         begin
            if Arg'Length /= 0 then
               if Arg (Arg'First) = '@' then
                  if Arg'Length = 1 then
                     Fail_Program
                       (null, "invalid argument '@' on the command line",
                        Exit_Code => E_General);
                  else
                     Read_File (Arg (Arg'First + 1 .. Arg'Last));
                  end if;

               else
                  Name_Len := Arg'Length;
                  Name_Buffer (1 .. Name_Len) := Arg;
                  Command_Line_Arguments.Append (Name_Find);
               end if;
            end if;
         end;
      end loop;
   end Get_Command_Line_Arguments;

   --------------------------------
   -- Last_Command_Line_Argument --
   --------------------------------

   function Last_Command_Line_Argument return Natural is
   begin
      return Command_Line_Arguments.Last;
   end Last_Command_Line_Argument;

   ---------------------------
   -- Command_Line_Argument --
   ---------------------------

   function Command_Line_Argument (Rank : Positive) return String is
   begin
      if Rank > Command_Line_Arguments.Last then
         return "";

      else
         return Get_Name_String (Command_Line_Arguments.Table (Rank));
      end if;
   end Command_Line_Argument;

begin
   declare
      Ext : String_Access := GNAT.OS_Lib.Get_Target_Executable_Suffix;
   begin
      Set_Name_Buffer (Ext.all);
      Executable_Extension_On_Target := Name_Enter;
      Free (Ext);
   end;
end GPR.Util;
