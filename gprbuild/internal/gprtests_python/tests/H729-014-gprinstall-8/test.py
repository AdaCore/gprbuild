import os
from gprbuild_utils import *

# For default

gprbuild (['-XOS=UNIX', 'prj/prj.gpr'])
gprinstall (['--prefix='+os.getcwd()+"/inst",
             '-XOS=UNIX', 'prj/prj.gpr'],
            output='tmp.out', verbose=True)

# For NT

gprbuild (['-XOS=Windows_NT', 'prj/prj.gpr'])
gprinstall (['--prefix='+os.getcwd()+"/inst",
             '-XOS=Windows_NT', '--build-name=nt', 'prj/prj.gpr'],
            output='tmp.out', verbose=True)

# For Darwin

gprinstall (['--prefix='+os.getcwd()+"/inst",
             '-XOS=Darwin', '--build-name=darwin', 'prj/prj.gpr'],
            output='tmp.out', verbose=True)

content = open ("inst/share/gpr/prj.gpr").readlines()

for l in content:
    if l[0:49] == '--  This project has been generated by GPRINSTALL':
        print l[0:49]
    else:
        print l.replace('\\', '/')