------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--          Copyright (C) 2001-2021, Free Software Foundation, Inc.         --
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

--  This package contains low level, operating system routines

with Ada.Calendar;
with Ada.Unchecked_Deallocation;

package GPR.Osint is

   -----------------------------------------
   -- Types Used for Text Buffer Handling --
   -----------------------------------------

   --  We can not use type String for text buffers, since we must use the
   --  standard 32-bit integer as an index value, since we count on all
   --  index values being the same size.

   subtype Text_Ptr is Source_Ptr;
   --  Type used for subscripts in text buffer

   type Text_Buffer is array (Text_Ptr range <>) of Character;
   --  Text buffer used to hold source file or library information file

   type Text_Buffer_Ptr is access all Text_Buffer;
   --  Text buffers for input files are allocated dynamically and this type
   --  is used to reference these text buffers.

   procedure Free is
     new Ada.Unchecked_Deallocation (Text_Buffer, Text_Buffer_Ptr);
   --  Procedure for freeing dynamically allocated text buffers

   ------------------------------------------
   -- Types Used for Source Input Handling --
   ------------------------------------------

   type Line_Number is range 0 .. Int'Last;
   for Line_Number'Size use 32;
   No_Line_Number : constant Line_Number := 0;
   --  Special value used to indicate no line number

   type Column_Number is range 0 .. 32767;
   for Column_Number'Size use 16;
   --  Column number (assume that 2**15 - 1 is large enough). The range for
   --  this type is used to compute Hostparm.Max_Line_Length. See also the
   --  processing for -gnatyM in Stylesw).

   No_Column_Number : constant Column_Number := 0;
   --  Special value used to indicate no column number

   Source_Align : constant := 2 ** 12;
   --  Alignment requirement for source buffers (by keeping source buffers
   --  aligned, we can optimize the implementation of Get_Source_File_Index.
   --  See this routine in Sinput for details.

   subtype Source_Buffer is Text_Buffer;
   --  Type used to store text of a source file. The buffer for the main source
   --  (the source specified on the command line) has a lower bound starting
   --  at zero. Subsequent subsidiary sources have lower bounds which are
   --  one greater than the previous upper bound, rounded up to a multiple
   --  of Source_Align.

   subtype Big_Source_Buffer is Text_Buffer (0 .. Text_Ptr'Last);
   --  This is a virtual type used as the designated type of the access type
   --  Source_Buffer_Ptr, see Osint.Read_Source_File for details.

   type Source_Buffer_Ptr is access all Big_Source_Buffer;
   --  Pointer to source buffer. We use virtual origin addressing for source
   --  buffers, with thin pointers. The pointer points to a virtual instance
   --  of type Big_Source_Buffer, where the actual type is in fact of type
   --  Source_Buffer. The address is adjusted so that the virtual origin
   --  addressing works correctly. See Osint.Read_Source_Buffer for further
   --  details. Again, as for Big_String_Ptr, we should never allocate using
   --  this type, but we don't give a storage size clause of zero, since we
   --  may end up doing deallocations of instances allocated manually.

   function Is_Directory_Separator (C : Character) return Boolean with Inline;
   --  Return True iff C is a directory separator inj a path

   function Get_Directory (Name : File_Name_Type) return File_Name_Type;
   --  Get the prefix directory name (if any) from Name. The last separator
   --  is preserved. Return the normalized current directory if there is no
   --  directory part in the name.

   function Executable_Name
     (Name              : File_Name_Type;
      Only_If_No_Suffix : Boolean := False) return File_Name_Type;
   --  Given a file name it adds the appropriate suffix at the end so that
   --  it becomes the name of the executable on the system at end. For
   --  instance under DOS it adds the ".exe" suffix, whereas under UNIX no
   --  suffix is added.

   function Strip_Suffix (Name : File_Name_Type) return File_Name_Type;
   --  Strips the suffix (the last '.' and whatever comes after it) from
   --  Name. Returns the stripped name.

   function Read_Library_Info
     (Lib_File  : File_Name_Type;
      Fatal_Err : Boolean := False) return Text_Buffer_Ptr;
   --  Allocates a Text_Buffer of appropriate length and reads in the entire
   --  source of the library information from the library information file
   --  whose name is given by the parameter Name.
   --
   --  See description of Read_Source_File for details on the format of the
   --  returned text buffer (the format is identical). The lower bound of
   --  the Text_Buffer is always zero
   --
   --  If the specified file cannot be opened, then the action depends on
   --  Fatal_Err. If Fatal_Err is True, an error message is given and the
   --  compilation is abandoned. Otherwise if Fatal_Err is False, then null
   --  is returned. Note that the Lib_File is a simple name which does not
   --  include any directory information. The implementation is responsible
   --  for searching for the file in appropriate directories.
   --
   --  If Opt.Check_Object_Consistency is set to True then this routine
   --  checks whether the object file corresponding to the Lib_File is
   --  consistent with it. The object file is inconsistent if the object
   --  does not exist or if it has an older time stamp than Lib_File. This
   --  check is not performed when the Lib_File is "locked" (i.e. read/only)
   --  because in this case the object file may be buried in a library. In
   --  case of inconsistencies Read_Library_Info behaves as if it did not
   --  find Lib_File (namely if Fatal_Err is False, null is returned).

   function Read_Library_Info_From_Full
     (Full_Lib_File : File_Name_Type;
      Lib_File_Attr : access File_Attributes;
      Fatal_Err     : Boolean := False) return Text_Buffer_Ptr;

   procedure Fail (S : String);
   pragma No_Return (Fail);
   --  Outputs error message S preceded by the name of the executing program
   --  and exits with E_Fatal. The output goes to standard error, except if
   --  special output is in effect (see Output).

   function Get_File_Names_Case_Sensitive return Int;
   pragma Import (C, Get_File_Names_Case_Sensitive,
                  "__gnat_get_file_names_case_sensitive");
   File_Names_Case_Sensitive : constant Boolean :=
                                 Get_File_Names_Case_Sensitive /= 0;
   --  Set to indicate whether the operating system convention is for file
   --  names to be case sensitive (e.g., in Unix, set True), or non case
   --  sensitive (e.g., in Windows, set False).

   function Get_Env_Vars_Case_Sensitive return Int;
   pragma Import (C, Get_Env_Vars_Case_Sensitive,
                  "__gnat_get_env_vars_case_sensitive");
   Env_Vars_Case_Sensitive : constant Boolean :=
                               Get_Env_Vars_Case_Sensitive /= 0;
   --  Set to indicate whether the operating system convention is for
   --  environment variable names to be case sensitive (e.g., in Unix, set
   --  True), or non case sensitive (e.g., in Windows, set False).

   procedure Canonical_Case_File_Name (S : in out String);
   --  Given a file name, converts it to canonical case form. For systems
   --  where file names are case sensitive, this procedure has no effect.
   --  If file names are not case sensitive (i.e. for example if you have
   --  the file "xyz.adb", you can refer to it as XYZ.adb or XyZ.AdB), then
   --  this call converts the given string to canonical all lower case form,
   --  so that two file names compare equal if they refer to the same file.

   procedure Canonical_Case_Env_Var_Name (S : in out String);
   --  Given an environment variable name, converts it to canonical
   --  case form. For systems where environment variable names are case
   --  sensitive, this procedure has no effect. If environment variable
   --  names are not case sensitive, then this call converts the given
   --  string to canonical all lower case form, so that two environment
   --  variable names compare equal if they refer to the same environment
   --  variable.

   function File_Time_Stamp
     (Name : C_File_Name;
      Attr : access File_Attributes) return OS_Time;
   function File_Time_Stamp
     (Name : Path_Name_Type;
      Attr : access File_Attributes) return Time_Stamp_Type;
   --  Return the time stamp of the file

   Invalid_Time : constant Ada.Calendar.Time;

   function File_Time_Stamp (Name : String) return Ada.Calendar.Time;
   --  Returns file last modification time with nanoseconds precision.
   --  Returns Invalid_Time on error.

   function File_Stamp (Name : File_Name_Type) return Time_Stamp_Type;
   --  Returns the time stamp of file Name. Name should include relative
   --  path information in order to locate it. If the source file cannot be
   --  opened, or Name = No_File, and all blank time stamp is returned (this
   --  is not an error situation).

   function File_Stamp (Name : Path_Name_Type) return Time_Stamp_Type;
   --  Same as above for a path name

   function File_Stamp (Name : String) return Time_Stamp_Type;
   --  Same as above for a string filename

   type Exit_Code_Type is
     (E_Success, -- No errors (but there may be warnings)
      E_General, -- General tool error (invalid option, missing file, etc)
      E_Subtool, -- Underlying tool error
      E_Project, -- Project parsing error
      E_Fatal);  -- Critical tool error (defensive code failures and the like)

   procedure Exit_Program (Exit_Code : Exit_Code_Type);
   pragma No_Return (Exit_Program);
   --  A call to Exit_Program terminates execution with the given status.
   --  A status of zero indicates normal completion, a non-zero status
   --  indicates abnormal termination.

private

   function File_Time_Stamp (N : C_File_Name) return Ada.Calendar.Time
     with Import, Convention => C, External_Name => "__gnat_file_time_name";

   Invalid_Time : constant Ada.Calendar.Time :=
                    File_Time_Stamp (System.Null_Address);

end GPR.Osint;
