from gprbuild_utils import *

def print_inst(lines):
    print lines[0]

    # cp or ln lines to be sorted
    cp=[]
    # remaining lines
    r=[]
    for l in lines[1:]:
        if l[0:3] == 'cp ' or l[0:3] == 'ln ':
            cp = cp + [l]
        else:
            r = r + [l]

    cp.sort()
    for l in cp:
        print l.replace('\\', '/').replace('.dll', '.so').replace('.dylib', '.so')
    for l in r:
        if l[0:49] == '--  This project has been generated by GPRINSTALL':
            print l[0:49]
        else:
            print l.replace('\\', '/')

gprbuild("-q -p prj.gpr")

print "==================== RUN 1"
gprinstall (['--no-lib-link', '--dry-run', '-a', '--prefix=/opt', 'prj.gpr'],
            output='tmp1.out', verbose=True)
print_inst (open('tmp1.out').readlines())

gprbuild("-q -p prjl.gpr")

print "==================== RUN 2"
gprinstall (['--no-lib-link', '--dry-run', '-a', '--prefix=/opt', 'prjl.gpr'],
            output='tmp2.out', verbose=True)
print_inst (open('tmp2.out').readlines())

gprbuild("-q -p prjn.gpr")

print "==================== RUN 3"
gprinstall (['--no-lib-link', '--dry-run', '-a', '--prefix=/opt', 'prjn.gpr'],
            output='tmp3.out', verbose=True)
print_inst (open('tmp3.out').readlines())

print "==================== RUN 4"
gprinstall (['--no-lib-link', '--dry-run', '-a', '--prefix=/toto', 'prjn.gpr'],
            output='tmp4.out', verbose=True)
print_inst (open('tmp4.out').readlines())

print "==================== RUN 5"
gprinstall (['--no-lib-link', '-XOS=Windows_NT', '--dry-run', '-a',
             '--prefix=/titi', 'prjn.gpr'],
            output='tmp5.out', verbose=True)
print_inst (open('tmp5.out').readlines())

gprbuild("-q -p prje.gpr")

print "==================== RUN 6"
gprinstall (['--no-lib-link', '--dry-run', '-a', '--prefix=/opt', 'prje.gpr'],
            output='tmp6.out', verbose=True)
print_inst (open('tmp6.out').readlines())

print "==================== RUN 7"
gprinstall (['--no-lib-link', '--dry-run', '--mode=usage', '-a',
             '--prefix=/opt', 'prjl.gpr'],
            output='tmp7.out', verbose=True)
print_inst (open('tmp7.out').readlines())

print "==================== RUN 8"
gprinstall (['--no-lib-link', '--dry-run', '--mode=usage', '-a',
             '--prefix=/opt', 'prjls.gpr'],
            output='tmp8.out', verbose=True)
print_inst (open('tmp8.out').readlines())

gprbuild("-f -q -p prjlstand.gpr")

print "==================== RUN 9"
gprinstall (['--no-lib-link', '--dry-run',  '-a', '--prefix=/opt',
             'prjlstand.gpr'],
            output='tmp9.out', verbose=True)
print_inst (open('tmp9.out').readlines())

gprbuild("-q -p prjlv.gpr")

print "==================== RUN 10"
gprinstall (['--no-lib-link', '--dry-run', '--prefix=/opt', '-a',
             '--build-name=fast', 'prjlv.gpr'],
            output='tmp10.out', verbose=True)
print_inst (open('tmp10.out').readlines())

print "==================== RUN 11"
gprinstall (['--no-lib-link', '--dry-run', '--prefix=/opt', 'prjna.gpr'],
            output='tmp11.out', verbose=True)
print (open('tmp11.out').readlines())
