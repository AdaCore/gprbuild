#include <stdlib.h>
extern void adainit (void);
extern void adafinal (void);
extern void do_it_in_ada(void);
int main (void) {
  adainit();
  do_it_in_ada ();
  adafinal();
  exit (0);
}


