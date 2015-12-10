///
/// @author S. S. Kapur     s.s.kapur@lmco.com
//
#ifndef CPP_ROOT_H
#define CPP_ROOT_H

#include <iomanip>
#include <iostream>

////////////////////////////////////////////////////////////////////////////////
/// Defines the base class that all suite model base classes must derive from.
///////////////////////////////////////////////////////////////////////////////

class Test2_Common_root {
public:
   Test2_Common_root();
   ~Test2_Common_root(){};
   virtual void execute();

   int          state;
};
#endif // CPP_ROOT_H
