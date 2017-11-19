------------------------------------------------------------------------------
--                                                                          --
--                           GPR PROJECT MANAGER                            --
--                                                                          --
--      Copyright (C) 2015-2017, Free Software Foundation, Inc.             --
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

package body GPR.Snames is

   procedure Add_Name (S : String);

   --------------
   -- Add_Name --
   --------------

   procedure Add_Name (S : String) is
      Dummy : Name_Id;
      pragma Warnings (Off, Dummy);
   begin
      Name_Len := 0;
      Add_Str_To_Name_Buffer (S);
      Dummy := Name_Find;
   end Add_Name;

   Initialized : Boolean := False;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      if Initialized then
         return;
      end if;

      if Last_Id = Name_Id'First then
         Add_Name ("");
      end if;

      Add_Name ("a");
      Add_Name ("b");
      Add_Name ("c");
      Add_Name ("d");
      Add_Name ("e");
      Add_Name ("f");
      Add_Name ("g");
      Add_Name ("h");
      Add_Name ("i");
      Add_Name ("j");
      Add_Name ("k");
      Add_Name ("l");
      Add_Name ("m");
      Add_Name ("n");
      Add_Name ("o");
      Add_Name ("p");
      Add_Name ("q");
      Add_Name ("r");
      Add_Name ("s");
      Add_Name ("t");
      Add_Name ("u");
      Add_Name ("v");
      Add_Name ("w");
      Add_Name ("x");
      Add_Name ("y");
      Add_Name ("z");
      Add_Name ("abort");
      Add_Name ("abs");
      Add_Name ("accept");
      Add_Name ("and");
      Add_Name ("all");
      Add_Name ("array");
      Add_Name ("at");
      Add_Name ("begin");
      Add_Name ("body");
      Add_Name ("case");
      Add_Name ("constant");
      Add_Name ("declare");
      Add_Name ("delay");
      Add_Name ("do");
      Add_Name ("else");
      Add_Name ("elsif");
      Add_Name ("end");
      Add_Name ("entry");
      Add_Name ("exception");
      Add_Name ("exit");
      Add_Name ("for");
      Add_Name ("function");
      Add_Name ("generic");
      Add_Name ("goto");
      Add_Name ("if");
      Add_Name ("in");
      Add_Name ("is");
      Add_Name ("limited");
      Add_Name ("loop");
      Add_Name ("new");
      Add_Name ("not");
      Add_Name ("null");
      Add_Name ("of");
      Add_Name ("or");
      Add_Name ("others");
      Add_Name ("out");
      Add_Name ("package");
      Add_Name ("pragma");
      Add_Name ("private");
      Add_Name ("procedure");
      Add_Name ("raise");
      Add_Name ("record");
      Add_Name ("rem");
      Add_Name ("renames");
      Add_Name ("return");
      Add_Name ("reverse");
      Add_Name ("select");
      Add_Name ("separate");
      Add_Name ("subtype");
      Add_Name ("task");
      Add_Name ("terminate");
      Add_Name ("then");
      Add_Name ("type");
      Add_Name ("use");
      Add_Name ("when");
      Add_Name ("while");
      Add_Name ("with");
      Add_Name ("xor");
      Add_Name ("access");
      Add_Name ("delta");
      Add_Name ("digits");
      Add_Name ("mod");
      Add_Name ("range");
      Add_Name ("abstract");
      Add_Name ("aliased");
      Add_Name ("protected");
      Add_Name ("until");
      Add_Name ("requeue");
      Add_Name ("tagged");
      Add_Name ("project");
      Add_Name ("extends");
      Add_Name ("external");
      Add_Name ("external_as_list");
      Add_Name ("interface");
      Add_Name ("overriding");
      Add_Name ("synchronized");
      Add_Name ("some");
      Add_Name ("active");
      Add_Name ("aggregate");
      Add_Name ("archive_builder");
      Add_Name ("archive_builder_append_option");
      Add_Name ("archive_indexer");
      Add_Name ("archive_suffix");
      Add_Name ("artifacts");
      Add_Name ("artifacts_in_exec_dir");
      Add_Name ("artifacts_in_object_dir");
      Add_Name ("binder");
      Add_Name ("body_suffix");
      Add_Name ("builder");
      Add_Name ("clean");
      Add_Name ("compiler");
      Add_Name ("compiler_command");
      Add_Name ("config_body_file_name");
      Add_Name ("config_body_file_name_index");
      Add_Name ("config_body_file_name_pattern");
      Add_Name ("config_file_switches");
      Add_Name ("config_file_unique");
      Add_Name ("config_spec_file_name");
      Add_Name ("config_spec_file_name_index");
      Add_Name ("config_spec_file_name_pattern");
      Add_Name ("configuration");
      Add_Name ("cross_reference");
      Add_Name ("default_language");
      Add_Name ("default_switches");
      Add_Name ("dependency_driver");
      Add_Name ("dependency_kind");
      Add_Name ("dependency_switches");
      Add_Name ("driver");
      Add_Name ("excluded_source_dirs");
      Add_Name ("excluded_source_files");
      Add_Name ("excluded_source_list_file");
      Add_Name ("exec_dir");
      Add_Name ("exec_subdir");
      Add_Name ("excluded_patterns");
      Add_Name ("executable");
      Add_Name ("executable_suffix");
      Add_Name ("externally_built");
      Add_Name ("finder");
      Add_Name ("global_compilation_switches");
      Add_Name ("global_configuration_pragmas");
      Add_Name ("global_config_file");
      Add_Name ("gnatls");
      Add_Name ("gnatstub");
      Add_Name ("gnu");
      Add_Name ("ide");
      Add_Name ("ignore_source_sub_dirs");
      Add_Name ("implementation");
      Add_Name ("implementation_exceptions");
      Add_Name ("implementation_suffix");
      Add_Name ("included_artifact_patterns");
      Add_Name ("included_patterns");
      Add_Name ("include_switches");
      Add_Name ("include_path");
      Add_Name ("include_path_file");
      Add_Name ("inherit_source_path");
      Add_Name ("install");
      Add_Name ("install_project");
      Add_Name ("languages");
      Add_Name ("language_kind");
      Add_Name ("leading_library_options");
      Add_Name ("leading_required_switches");
      Add_Name ("leading_switches");
      Add_Name ("ali_subdir");
      Add_Name ("lib_subdir");
      Add_Name ("link_lib_subdir");
      Add_Name ("library");
      Add_Name ("library_ali_dir");
      Add_Name ("library_auto_init");
      Add_Name ("library_auto_init_supported");
      Add_Name ("library_builder");
      Add_Name ("library_dir");
      Add_Name ("library_gcc");
      Add_Name ("library_install_name_option");
      Add_Name ("library_interface");
      Add_Name ("library_kind");
      Add_Name ("library_name");
      Add_Name ("library_major_minor_id_supported");
      Add_Name ("library_options");
      Add_Name ("library_partial_linker");
      Add_Name ("library_rpath_options");
      Add_Name ("library_standalone");
      Add_Name ("library_encapsulated_options");
      Add_Name ("library_encapsulated_supported");
      Add_Name ("library_src_dir");
      Add_Name ("library_support");
      Add_Name ("library_symbol_file");
      Add_Name ("library_symbol_policy");
      Add_Name ("library_version");
      Add_Name ("library_version_switches");
      Add_Name ("linker");
      Add_Name ("linker_executable_option");
      Add_Name ("linker_lib_dir_option");
      Add_Name ("linker_lib_name_option");
      Add_Name ("local_config_file");
      Add_Name ("local_configuration_pragmas");
      Add_Name ("locally_removed_files");
      Add_Name ("map_file_option");
      Add_Name ("mapping_file_switches");
      Add_Name ("mapping_spec_suffix");
      Add_Name ("mapping_body_suffix");
      Add_Name ("max_command_line_length");
      Add_Name ("metrics");
      Add_Name ("multi_unit_object_separator");
      Add_Name ("multi_unit_switches");
      Add_Name ("naming");
      Add_Name ("none");
      Add_Name ("object_artifact_extensions");
      Add_Name ("object_file_suffix");
      Add_Name ("object_file_switches");
      Add_Name ("object_generated");
      Add_Name ("object_list");
      Add_Name ("object_path_switches");
      Add_Name ("objects_linked");
      Add_Name ("objects_path");
      Add_Name ("objects_path_file");
      Add_Name ("object_dir");
      Add_Name ("option_list");
      Add_Name ("path_syntax");
      Add_Name ("pic_option");
      Add_Name ("pretty_printer");
      Add_Name ("prefix");
      Add_Name ("project_dir");
      Add_Name ("project_files");
      Add_Name ("project_path");
      Add_Name ("project_subdir");
      Add_Name ("remote");
      Add_Name ("response_file_format");
      Add_Name ("response_file_switches");
      Add_Name ("root_dir");
      Add_Name ("roots");
      Add_Name ("required_artifacts");
      Add_Name ("required_switches");
      Add_Name ("run_path_option");
      Add_Name ("run_path_origin");
      Add_Name ("separate_run_path_options");
      Add_Name ("shared_library_minimum_switches");
      Add_Name ("shared_library_prefix");
      Add_Name ("shared_library_suffix");
      Add_Name ("separate_suffix");
      Add_Name ("side_debug");
      Add_Name ("source_artifact_extensions");
      Add_Name ("source_dirs");
      Add_Name ("source_file_switches");
      Add_Name ("source_files");
      Add_Name ("source_list_file");
      Add_Name ("sources_subdir");
      Add_Name ("spec");
      Add_Name ("spec_suffix");
      Add_Name ("specification");
      Add_Name ("specification_exceptions");
      Add_Name ("specification_suffix");
      Add_Name ("stack");
      Add_Name ("switches");
      Add_Name ("symbolic_link_supported");
      Add_Name ("toolchain_description");
      Add_Name ("toolchain_version");
      Add_Name ("trailing_required_switches");
      Add_Name ("trailing_switches");
      Add_Name ("runtime_library_dir");
      Add_Name ("runtime_library_dirs");
      Add_Name ("runtime_source_dir");
      Add_Name ("ada");
      Add_Name ("interfaces");
      Add_Name ("main");
      Add_Name ("target");
      Add_Name ("casing");
      Add_Name ("dot_replacement");
      Add_Name ("standard");
      Add_Name ("name");
      Add_Name ("linker_options");
      Add_Name ("runtime");
      Add_Name ("mode");
      Add_Name ("install_name");
      Add_Name ("object_lister");
      Add_Name ("object_lister_matcher");
      Add_Name ("export_file_format");
      Add_Name ("export_file_switch");
      Add_Name ("runtime_source_dirs");
      Add_Name ("runtime_dir");
      Add_Name ("runtime_library_version");
      Add_Name ("split");
      Add_Name ("create_missing_dirs");

      Initialized := True;
   end Initialize;

end GPR.Snames;
