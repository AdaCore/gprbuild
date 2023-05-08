------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--        Copyright (C) 2015-2022, Free Software Foundation, Inc.           --
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

with GNAT.Source_Info;

package GPR.Snames is

   function L return Positive renames GNAT.Source_Info.Line;
   --  Static line number

   --  Constant values in the following block are assigned automatically
   --  based on the line number of the constant. For this to work correctly,
   --  the block must be contiguous, without empty or comment lines until
   --  the "End of empty lines prohibition" comment.

   N : constant Name_Id := Name_Id (L) - First_Name_Id; -- No empty lines below
   Name_C                                : constant Name_Id := Name_Id (L) - N;
   Name_Abort                            : constant Name_Id := Name_Id (L) - N;
   Name_Abs                              : constant Name_Id := Name_Id (L) - N;
   Name_Accept                           : constant Name_Id := Name_Id (L) - N;
   Name_And                              : constant Name_Id := Name_Id (L) - N;
   Name_All                              : constant Name_Id := Name_Id (L) - N;
   Name_Array                            : constant Name_Id := Name_Id (L) - N;
   Name_At                               : constant Name_Id := Name_Id (L) - N;
   Name_Begin                            : constant Name_Id := Name_Id (L) - N;
   Name_Body                             : constant Name_Id := Name_Id (L) - N;
   Name_Case                             : constant Name_Id := Name_Id (L) - N;
   Name_Constant                         : constant Name_Id := Name_Id (L) - N;
   Name_Declare                          : constant Name_Id := Name_Id (L) - N;
   Name_Delay                            : constant Name_Id := Name_Id (L) - N;
   Name_Do                               : constant Name_Id := Name_Id (L) - N;
   Name_Else                             : constant Name_Id := Name_Id (L) - N;
   Name_Elsif                            : constant Name_Id := Name_Id (L) - N;
   Name_End                              : constant Name_Id := Name_Id (L) - N;
   Name_Entry                            : constant Name_Id := Name_Id (L) - N;
   Name_Exception                        : constant Name_Id := Name_Id (L) - N;
   Name_Exit                             : constant Name_Id := Name_Id (L) - N;
   Name_For                              : constant Name_Id := Name_Id (L) - N;
   Name_Function                         : constant Name_Id := Name_Id (L) - N;
   Name_Generic                          : constant Name_Id := Name_Id (L) - N;
   Name_Goto                             : constant Name_Id := Name_Id (L) - N;
   Name_If                               : constant Name_Id := Name_Id (L) - N;
   Name_In                               : constant Name_Id := Name_Id (L) - N;
   Name_Is                               : constant Name_Id := Name_Id (L) - N;
   Name_Limited                          : constant Name_Id := Name_Id (L) - N;
   Name_Loop                             : constant Name_Id := Name_Id (L) - N;
   Name_New                              : constant Name_Id := Name_Id (L) - N;
   Name_Not                              : constant Name_Id := Name_Id (L) - N;
   Name_Null                             : constant Name_Id := Name_Id (L) - N;
   Name_Of                               : constant Name_Id := Name_Id (L) - N;
   Name_Or                               : constant Name_Id := Name_Id (L) - N;
   Name_Others                           : constant Name_Id := Name_Id (L) - N;
   Name_Out                              : constant Name_Id := Name_Id (L) - N;
   Name_Package                          : constant Name_Id := Name_Id (L) - N;
   Name_Pragma                           : constant Name_Id := Name_Id (L) - N;
   Name_Private                          : constant Name_Id := Name_Id (L) - N;
   Name_Procedure                        : constant Name_Id := Name_Id (L) - N;
   Name_Raise                            : constant Name_Id := Name_Id (L) - N;
   Name_Record                           : constant Name_Id := Name_Id (L) - N;
   Name_Rem                              : constant Name_Id := Name_Id (L) - N;
   Name_Renames                          : constant Name_Id := Name_Id (L) - N;
   Name_Return                           : constant Name_Id := Name_Id (L) - N;
   Name_Reverse                          : constant Name_Id := Name_Id (L) - N;
   Name_Select                           : constant Name_Id := Name_Id (L) - N;
   Name_Separate                         : constant Name_Id := Name_Id (L) - N;
   Name_Subtype                          : constant Name_Id := Name_Id (L) - N;
   Name_Task                             : constant Name_Id := Name_Id (L) - N;
   Name_Terminate                        : constant Name_Id := Name_Id (L) - N;
   Name_Then                             : constant Name_Id := Name_Id (L) - N;
   Name_Type                             : constant Name_Id := Name_Id (L) - N;
   Name_Use                              : constant Name_Id := Name_Id (L) - N;
   Name_When                             : constant Name_Id := Name_Id (L) - N;
   Name_While                            : constant Name_Id := Name_Id (L) - N;
   Name_With                             : constant Name_Id := Name_Id (L) - N;
   Name_Xor                              : constant Name_Id := Name_Id (L) - N;
   Name_Access                           : constant Name_Id := Name_Id (L) - N;
   Name_Delta                            : constant Name_Id := Name_Id (L) - N;
   Name_Digits                           : constant Name_Id := Name_Id (L) - N;
   Name_Mod                              : constant Name_Id := Name_Id (L) - N;
   Name_Range                            : constant Name_Id := Name_Id (L) - N;
   Name_Abstract                         : constant Name_Id := Name_Id (L) - N;
   Name_Aliased                          : constant Name_Id := Name_Id (L) - N;
   Name_Protected                        : constant Name_Id := Name_Id (L) - N;
   Name_Until                            : constant Name_Id := Name_Id (L) - N;
   Name_Requeue                          : constant Name_Id := Name_Id (L) - N;
   Name_Tagged                           : constant Name_Id := Name_Id (L) - N;
   Name_Project                          : constant Name_Id := Name_Id (L) - N;
   Name_Extends                          : constant Name_Id := Name_Id (L) - N;
   Name_External                         : constant Name_Id := Name_Id (L) - N;
   Name_External_As_List                 : constant Name_Id := Name_Id (L) - N;
   Name_Interface                        : constant Name_Id := Name_Id (L) - N;
   Name_Overriding                       : constant Name_Id := Name_Id (L) - N;
   Name_Synchronized                     : constant Name_Id := Name_Id (L) - N;
   Name_Some                             : constant Name_Id := Name_Id (L) - N;
   Name_Active                           : constant Name_Id := Name_Id (L) - N;
   Name_Aggregate                        : constant Name_Id := Name_Id (L) - N;
   Name_Archive_Builder                  : constant Name_Id := Name_Id (L) - N;
   Name_Archive_Builder_Append_Option    : constant Name_Id := Name_Id (L) - N;
   Name_Archive_Indexer                  : constant Name_Id := Name_Id (L) - N;
   Name_Archive_Suffix                   : constant Name_Id := Name_Id (L) - N;
   Name_Artifacts                        : constant Name_Id := Name_Id (L) - N;
   Name_Artifacts_In_Exec_Dir            : constant Name_Id := Name_Id (L) - N;
   Name_Artifacts_In_Object_Dir          : constant Name_Id := Name_Id (L) - N;
   Name_Binder                           : constant Name_Id := Name_Id (L) - N;
   Name_Bindfile_Option_Substitution     : constant Name_Id := Name_Id (L) - N;
   Name_Body_Suffix                      : constant Name_Id := Name_Id (L) - N;
   Name_Builder                          : constant Name_Id := Name_Id (L) - N;
   Name_Clean                            : constant Name_Id := Name_Id (L) - N;
   Name_Compiler                         : constant Name_Id := Name_Id (L) - N;
   Name_Compiler_Command                 : constant Name_Id := Name_Id (L) - N;
   Name_Config_Body_File_Name            : constant Name_Id := Name_Id (L) - N;
   Name_Config_Body_File_Name_Index      : constant Name_Id := Name_Id (L) - N;
   Name_Config_Body_File_Name_Pattern    : constant Name_Id := Name_Id (L) - N;
   Name_Config_File_Dependency_Support   : constant Name_Id := Name_Id (L) - N;
   Name_Config_File_Switches             : constant Name_Id := Name_Id (L) - N;
   Name_Config_File_Unique               : constant Name_Id := Name_Id (L) - N;
   Name_Config_Spec_File_Name            : constant Name_Id := Name_Id (L) - N;
   Name_Config_Spec_File_Name_Index      : constant Name_Id := Name_Id (L) - N;
   Name_Config_Spec_File_Name_Pattern    : constant Name_Id := Name_Id (L) - N;
   Name_Configuration                    : constant Name_Id := Name_Id (L) - N;
   Name_Cross_Reference                  : constant Name_Id := Name_Id (L) - N;
   Name_Def                              : constant Name_Id := Name_Id (L) - N;
   Name_Default_Language                 : constant Name_Id := Name_Id (L) - N;
   Name_Default_Switches                 : constant Name_Id := Name_Id (L) - N;
   Name_Dependency_Driver                : constant Name_Id := Name_Id (L) - N;
   Name_Dependency_Kind                  : constant Name_Id := Name_Id (L) - N;
   Name_Dependency_Switches              : constant Name_Id := Name_Id (L) - N;
   Name_Driver                           : constant Name_Id := Name_Id (L) - N;
   Name_Excluded_Source_Dirs             : constant Name_Id := Name_Id (L) - N;
   Name_Excluded_Source_Files            : constant Name_Id := Name_Id (L) - N;
   Name_Excluded_Source_List_File        : constant Name_Id := Name_Id (L) - N;
   Name_Exec_Dir                         : constant Name_Id := Name_Id (L) - N;
   Name_Exec_Subdir                      : constant Name_Id := Name_Id (L) - N;
   Name_Excluded_Patterns                : constant Name_Id := Name_Id (L) - N;
   Name_Executable                       : constant Name_Id := Name_Id (L) - N;
   Name_Executable_Suffix                : constant Name_Id := Name_Id (L) - N;
   Name_Externally_Built                 : constant Name_Id := Name_Id (L) - N;
   Name_Finder                           : constant Name_Id := Name_Id (L) - N;
   Name_Flat                             : constant Name_Id := Name_Id (L) - N;
   Name_Gcc                              : constant Name_Id := Name_Id (L) - N;
   Name_Gcc_Gnu                          : constant Name_Id := Name_Id (L) - N;
   Name_Gcc_Option_List                  : constant Name_Id := Name_Id (L) - N;
   Name_Gcc_Object_List                  : constant Name_Id := Name_Id (L) - N;
   Name_Global_Compilation_Switches      : constant Name_Id := Name_Id (L) - N;
   Name_Global_Configuration_Pragmas     : constant Name_Id := Name_Id (L) - N;
   Name_Global_Config_File               : constant Name_Id := Name_Id (L) - N;
   Name_Gnatls                           : constant Name_Id := Name_Id (L) - N;
   Name_Gnatstub                         : constant Name_Id := Name_Id (L) - N;
   Name_Gnu                              : constant Name_Id := Name_Id (L) - N;
   Name_Ide                              : constant Name_Id := Name_Id (L) - N;
   Name_Ignore_Source_Sub_Dirs           : constant Name_Id := Name_Id (L) - N;
   Name_Implementation                   : constant Name_Id := Name_Id (L) - N;
   Name_Implementation_Exceptions        : constant Name_Id := Name_Id (L) - N;
   Name_Implementation_Suffix            : constant Name_Id := Name_Id (L) - N;
   Name_Included_Artifact_Patterns       : constant Name_Id := Name_Id (L) - N;
   Name_Included_Patterns                : constant Name_Id := Name_Id (L) - N;
   Name_Include_Switches                 : constant Name_Id := Name_Id (L) - N;
   Name_Include_Path                     : constant Name_Id := Name_Id (L) - N;
   Name_Include_Path_File                : constant Name_Id := Name_Id (L) - N;
   Name_Inherit_Source_Path              : constant Name_Id := Name_Id (L) - N;
   Name_Install                          : constant Name_Id := Name_Id (L) - N;
   Name_Install_Project                  : constant Name_Id := Name_Id (L) - N;
   Name_Languages                        : constant Name_Id := Name_Id (L) - N;
   Name_Language_Kind                    : constant Name_Id := Name_Id (L) - N;
   Name_Leading_Library_Options          : constant Name_Id := Name_Id (L) - N;
   Name_Leading_Required_Switches        : constant Name_Id := Name_Id (L) - N;
   Name_Leading_Switches                 : constant Name_Id := Name_Id (L) - N;
   Name_ALI_Subdir                       : constant Name_Id := Name_Id (L) - N;
   Name_Lib_Subdir                       : constant Name_Id := Name_Id (L) - N;
   Name_Link_Lib_Subdir                  : constant Name_Id := Name_Id (L) - N;
   Name_Library                          : constant Name_Id := Name_Id (L) - N;
   Name_Library_Ali_Dir                  : constant Name_Id := Name_Id (L) - N;
   Name_Library_Auto_Init                : constant Name_Id := Name_Id (L) - N;
   Name_Library_Auto_Init_Supported      : constant Name_Id := Name_Id (L) - N;
   Name_Library_Builder                  : constant Name_Id := Name_Id (L) - N;
   Name_Library_Dir                      : constant Name_Id := Name_Id (L) - N;
   Name_Library_GCC                      : constant Name_Id := Name_Id (L) - N;
   Name_Library_Install_Name_Option      : constant Name_Id := Name_Id (L) - N;
   Name_Library_Interface                : constant Name_Id := Name_Id (L) - N;
   Name_Library_Kind                     : constant Name_Id := Name_Id (L) - N;
   Name_Library_Name                     : constant Name_Id := Name_Id (L) - N;
   Name_Library_Major_Minor_Id_Supported : constant Name_Id := Name_Id (L) - N;
   Name_Library_Options                  : constant Name_Id := Name_Id (L) - N;
   Name_Library_Partial_Linker           : constant Name_Id := Name_Id (L) - N;
   Name_Library_Rpath_Options            : constant Name_Id := Name_Id (L) - N;
   Name_Library_Standalone               : constant Name_Id := Name_Id (L) - N;
   Name_Library_Encapsulated_Options     : constant Name_Id := Name_Id (L) - N;
   Name_Library_Encapsulated_Supported   : constant Name_Id := Name_Id (L) - N;
   Name_Library_Src_Dir                  : constant Name_Id := Name_Id (L) - N;
   Name_Library_Support                  : constant Name_Id := Name_Id (L) - N;
   Name_Library_Symbol_File              : constant Name_Id := Name_Id (L) - N;
   Name_Library_Symbol_Policy            : constant Name_Id := Name_Id (L) - N;
   Name_Library_Version                  : constant Name_Id := Name_Id (L) - N;
   Name_Library_Version_Switches         : constant Name_Id := Name_Id (L) - N;
   Name_Linker                           : constant Name_Id := Name_Id (L) - N;
   Name_Linker_Executable_Option         : constant Name_Id := Name_Id (L) - N;
   Name_Linker_Lib_Dir_Option            : constant Name_Id := Name_Id (L) - N;
   Name_Linker_Lib_Name_Option           : constant Name_Id := Name_Id (L) - N;
   Name_Local_Config_File                : constant Name_Id := Name_Id (L) - N;
   Name_Local_Configuration_Pragmas      : constant Name_Id := Name_Id (L) - N;
   Name_Locally_Removed_Files            : constant Name_Id := Name_Id (L) - N;
   Name_Map_File_Option                  : constant Name_Id := Name_Id (L) - N;
   Name_Mapping_File_Switches            : constant Name_Id := Name_Id (L) - N;
   Name_Mapping_Spec_Suffix              : constant Name_Id := Name_Id (L) - N;
   Name_Mapping_Body_Suffix              : constant Name_Id := Name_Id (L) - N;
   Name_Max_Command_Line_Length          : constant Name_Id := Name_Id (L) - N;
   Name_Metrics                          : constant Name_Id := Name_Id (L) - N;
   Name_Multi_Unit_Object_Separator      : constant Name_Id := Name_Id (L) - N;
   Name_Multi_Unit_Switches              : constant Name_Id := Name_Id (L) - N;
   Name_Naming                           : constant Name_Id := Name_Id (L) - N;
   Name_None                             : constant Name_Id := Name_Id (L) - N;
   Name_Object_Artifact_Extensions       : constant Name_Id := Name_Id (L) - N;
   Name_Object_File_Prefix               : constant Name_Id := Name_Id (L) - N;
   Name_Object_File_Suffix               : constant Name_Id := Name_Id (L) - N;
   Name_Object_File_Switches             : constant Name_Id := Name_Id (L) - N;
   Name_Object_Generated                 : constant Name_Id := Name_Id (L) - N;
   Name_Object_List                      : constant Name_Id := Name_Id (L) - N;
   Name_Object_Path_Switches             : constant Name_Id := Name_Id (L) - N;
   Name_Objects_Linked                   : constant Name_Id := Name_Id (L) - N;
   Name_Objects_Path                     : constant Name_Id := Name_Id (L) - N;
   Name_Objects_Path_File                : constant Name_Id := Name_Id (L) - N;
   Name_Object_Dir                       : constant Name_Id := Name_Id (L) - N;
   Name_Option_List                      : constant Name_Id := Name_Id (L) - N;
   Name_Pic_Option                       : constant Name_Id := Name_Id (L) - N;
   Name_Pretty_Printer                   : constant Name_Id := Name_Id (L) - N;
   Name_Prefix                           : constant Name_Id := Name_Id (L) - N;
   Name_Project_Dir                      : constant Name_Id := Name_Id (L) - N;
   Name_Project_Files                    : constant Name_Id := Name_Id (L) - N;
   Name_Project_Path                     : constant Name_Id := Name_Id (L) - N;
   Name_Project_Subdir                   : constant Name_Id := Name_Id (L) - N;
   Name_Remote                           : constant Name_Id := Name_Id (L) - N;
   Name_Response_File_Format             : constant Name_Id := Name_Id (L) - N;
   Name_Response_File_Switches           : constant Name_Id := Name_Id (L) - N;
   Name_Root_Dir                         : constant Name_Id := Name_Id (L) - N;
   Name_Roots                            : constant Name_Id := Name_Id (L) - N;
   Name_Required_Artifacts               : constant Name_Id := Name_Id (L) - N;
   Name_Required_Switches                : constant Name_Id := Name_Id (L) - N;
   Name_Run_Path_Option                  : constant Name_Id := Name_Id (L) - N;
   Name_Run_Path_Origin                  : constant Name_Id := Name_Id (L) - N;
   Name_Separate_Run_Path_Options        : constant Name_Id := Name_Id (L) - N;
   Name_Shared_Library_Minimum_Switches  : constant Name_Id := Name_Id (L) - N;
   Name_Shared_Library_Prefix            : constant Name_Id := Name_Id (L) - N;
   Name_Shared_Library_Suffix            : constant Name_Id := Name_Id (L) - N;
   Name_Separate_Suffix                  : constant Name_Id := Name_Id (L) - N;
   Name_Side_Debug                       : constant Name_Id := Name_Id (L) - N;
   Name_Source_Artifact_Extensions       : constant Name_Id := Name_Id (L) - N;
   Name_Source_Dirs                      : constant Name_Id := Name_Id (L) - N;
   Name_Source_File_Switches             : constant Name_Id := Name_Id (L) - N;
   Name_Source_Files                     : constant Name_Id := Name_Id (L) - N;
   Name_Source_List_File                 : constant Name_Id := Name_Id (L) - N;
   Name_Sources_Subdir                   : constant Name_Id := Name_Id (L) - N;
   Name_Spec                             : constant Name_Id := Name_Id (L) - N;
   Name_Spec_Suffix                      : constant Name_Id := Name_Id (L) - N;
   Name_Specification                    : constant Name_Id := Name_Id (L) - N;
   Name_Specification_Exceptions         : constant Name_Id := Name_Id (L) - N;
   Name_Specification_Suffix             : constant Name_Id := Name_Id (L) - N;
   Name_Stack                            : constant Name_Id := Name_Id (L) - N;
   Name_Switches                         : constant Name_Id := Name_Id (L) - N;
   Name_Symbolic_Link_Supported          : constant Name_Id := Name_Id (L) - N;
   Name_Toolchain_Description            : constant Name_Id := Name_Id (L) - N;
   Name_Toolchain_Version                : constant Name_Id := Name_Id (L) - N;
   Name_Trailing_Required_Switches       : constant Name_Id := Name_Id (L) - N;
   Name_Trailing_Switches                : constant Name_Id := Name_Id (L) - N;
   Name_Runtime_Library_Dir              : constant Name_Id := Name_Id (L) - N;
   Name_Runtime_Library_Dirs             : constant Name_Id := Name_Id (L) - N;
   Name_Runtime_Source_Dir               : constant Name_Id := Name_Id (L) - N;
   Name_Ada                              : constant Name_Id := Name_Id (L) - N;
   Name_Interfaces                       : constant Name_Id := Name_Id (L) - N;
   Name_Main                             : constant Name_Id := Name_Id (L) - N;
   Name_Target                           : constant Name_Id := Name_Id (L) - N;
   Name_Casing                           : constant Name_Id := Name_Id (L) - N;
   Name_Dot_Replacement                  : constant Name_Id := Name_Id (L) - N;
   Name_Standard                         : constant Name_Id := Name_Id (L) - N;
   Name_Name                             : constant Name_Id := Name_Id (L) - N;
   Name_Linker_Options                   : constant Name_Id := Name_Id (L) - N;
   Name_Runtime                          : constant Name_Id := Name_Id (L) - N;
   Name_Mode                             : constant Name_Id := Name_Id (L) - N;
   Name_Install_Name                     : constant Name_Id := Name_Id (L) - N;
   Name_Object_Lister                    : constant Name_Id := Name_Id (L) - N;
   Name_Object_Lister_Matcher            : constant Name_Id := Name_Id (L) - N;
   Name_Export_File_Format               : constant Name_Id := Name_Id (L) - N;
   Name_Export_File_Switch               : constant Name_Id := Name_Id (L) - N;
   Name_Runtime_Source_Dirs              : constant Name_Id := Name_Id (L) - N;
   Name_Runtime_Dir                      : constant Name_Id := Name_Id (L) - N;
   Name_Runtime_Library_Version          : constant Name_Id := Name_Id (L) - N;
   Name_Split                            : constant Name_Id := Name_Id (L) - N;
   Name_Create_Missing_Dirs              : constant Name_Id := Name_Id (L) - N;
   Name_Canonical_Target                 : constant Name_Id := Name_Id (L) - N;
   Name_Warning_Message                  : constant Name_Id := Name_Id (L) - N;
   Name_Only_Dirs_With_Sources           : constant Name_Id := Name_Id (L) - N;
   Name_Include_Switches_Via_Spec        : constant Name_Id := Name_Id (L) - N;
   Name_Required_Toolchain_Version       : constant Name_Id := Name_Id (L) - N;
   Name_Toolchain_Name                   : constant Name_Id := Name_Id (L) - N;
   Name_Check                            : constant Name_Id := Name_Id (L) - N;
   Name_Eliminate                        : constant Name_Id := Name_Id (L) - N;
   Name_Remote_Host                      : constant Name_Id := Name_Id (L) - N;
   Name_Program_Host                     : constant Name_Id := Name_Id (L) - N;
   Name_Communication_Protocol           : constant Name_Id := Name_Id (L) - N;
   Name_Debugger_Command                 : constant Name_Id := Name_Id (L) - N;
   Name_Gnatlist                         : constant Name_Id := Name_Id (L) - N;
   Name_Vcs_Kind                         : constant Name_Id := Name_Id (L) - N;
   Name_Vcs_File_Check                   : constant Name_Id := Name_Id (L) - N;
   Name_Vcs_Log_Check                    : constant Name_Id := Name_Id (L) - N;
   Name_Documentation_Dir                : constant Name_Id := Name_Id (L) - N;
   Name_Codepeer                         : constant Name_Id := Name_Id (L) - N;
   Name_Output_Directory                 : constant Name_Id := Name_Id (L) - N;
   Name_Database_Directory               : constant Name_Id := Name_Id (L) - N;
   Name_Message_Patterns                 : constant Name_Id := Name_Id (L) - N;
   Name_Additional_Patterns              : constant Name_Id := Name_Id (L) - N;
   Name_Origin_Project                   : constant Name_Id := Name_Id (L) - N;
   Name_Library_Reference_Symbol_File    : constant Name_Id := Name_Id (L) - N;
   Name_Unconditional_Linking            : constant Name_Id := Name_Id (L) - N;
   Name_Toolchain_Path                   : constant Name_Id := Name_Id (L) - N;
   The_Empty_String                      : constant Name_Id := Name_Id (L) - N;
   The_Dot_String                        : constant Name_Id := Name_Id (L) - N;
   The_Star_String                       : constant Name_Id := Name_Id (L) - N;
   --  End of empty lines prohibition

   subtype Reserved_Ada_95 is Name_Id
      range Name_Abort .. Name_Tagged;
   subtype Reserved_Ada_Project is Name_Id
      range Name_Abort .. Name_External_As_List;
   subtype Reserved_Ada_Other is Name_Id
      range Name_Interface .. Name_Some;

   procedure Initialize;

end GPR.Snames;
