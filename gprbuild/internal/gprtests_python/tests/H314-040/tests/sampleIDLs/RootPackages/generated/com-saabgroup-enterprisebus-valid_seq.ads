--  ============================================================================
--
--         WARNING: THIS FILE IS AUTO-GENERATED. DO NOT MODIFY.
--
--  This file was generated from com_saabgroup_enterprisebus.idl using "rtiddsgen".
--  The rtiddsgen tool is part of the RTI Data Distribution Service distribution.
--  For more information, type 'rtiddsgen -help' at a command shell
--  or consult the RTI Data Distribution Service manual.
--
--  ============================================================================

with DDS.Sequences_Generic;
with com.saabgroup.enterprisebus.VALID; use com.saabgroup.enterprisebus.VALID;

package com.saabgroup.enterprisebus.VALID_Seq is new DDS.Sequences_Generic
  (com.saabgroup.enterprisebus.VALID.VALID,
   com.saabgroup.enterprisebus.VALID.VALID_Access,
   Natural,
   1,
   com.saabgroup.enterprisebus.VALID.VALID_Array);

