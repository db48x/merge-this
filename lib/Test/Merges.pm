package Test::Merges;
use strict;
use warnings;
use feature qw( switch );
use autodie qw( system );
use base qw( Exporter Test::Builder::Module );
use Cwd;

use Try::Tiny;

our ( @EXPORT, $repository_dir );
BEGIN {
    @EXPORT = qw{
        add
        branch
        commit
        file
        merge_ok
        sed
        replace
        move
    };

    $repository_dir = $ENV{'PWD'} . "/repos"
}

sub import {
    my ($class) = @_;
    system "rm -rf repos";
    mkdir 'repos';
    chdir 'repos';
    mkdir 'initial';
    chdir 'initial';
    init();

    $class->export_to_level(1, @_);
}

sub pass {
    my ($name) = @_;
    __PACKAGE__->builder->ok( 1, $name );
}

sub fail {
    my ($name) = @_;
    __PACKAGE__->builder->ok( 0, $name );
}

sub file {
    my ($name, $content) = @_;

    open my $fh, '>', $name;
    print $fh $content;
    close $fh;
}

sub do_system {
    if (defined(${ENV{LOG}})) {
        print @_; print "\n";
    }
    system @_;
}

################# Repository actions ###################

# initialize a repository in the current directory
sub init {
    given($ENV{VCS}) {
        when('bzr')   { system "bzr init" }
        when('darcs') { system "darcs init" }
        when('git')   { system "git init" }
        when('hg')    { system "hg init" }
        when('svn')   { my $current_path = cwd();
                        my $current_dir = qx"basename ${current_path}";
                        chomp $current_dir;
                        chdir "..";
                        if ( -d "$repository_dir/svn_repo" ) {
                            do_system "rm -rf $repository_dir/svn_repo"
                        }
                        if ( -d "$repository_dir/svn_temp" ) {
                            do_system "rm -rf $repository_dir/svn_temp"
                        }
                        do_system "svnadmin create ${repository_dir}/svn_repo";
                        do_system "svn checkout file://${repository_dir}/svn_repo svn_temp";
                        chdir "svn_temp";
                        do_system "mkdir ${current_dir}";
                        do_system "svn add ${current_dir}";
                        do_system "svn commit -m 'create repository'";
                        chdir "..";
                        do_system "svn checkout file://${repository_dir}/svn_repo/${current_dir} ${current_dir}";
                        chdir $current_dir;
                      }
        default       { die "Must specify VCS environment\n" }
    }
}

# tell VCS to track some files
sub add {
    my @files = @_;
    given($ENV{VCS}) {
        when('bzr')   { system "bzr add @files" }
        when('darcs') { system "darcs add @files" }
        when('git')   { system "git add @files" }
        when('hg')    { system "hg  add @files" }
        when('svn')   { do_system "svn add @files" }
    }
}

# commits all changes made to the current repository
sub commit {
    my ($message) = @_;
    given($ENV{VCS}) {
        when('bzr') { system "bzr commit -m '$message'" }
        when('darcs') {
            system "darcs record -a --skip-long-comment -m '$message'"
        }
        when('git') { system "git commit -a -m '$message'" }
        when('hg')  { system "hg  commit -m '$message'" }
        when('svn') { do_system "svn commit -m '$message'" }
    }
}

# create a new repository from an existing one
sub clone {
    my ($source,$target) = @_;
    given($ENV{VCS}) {
        when('bzr') { system "bzr branch $source $target" }
        when('darcs') {
            system "darcs get --set-scripts-executable $source $target"
        }
        when('git') { system "git clone $source $target" }
        when('hg')  { system "hg  clone $source $target" }
        when('svn') { do_system "svn cp file://${repository_dir}/svn_repo/$source file://${repository_dir}/svn_repo/$target -m 'create branch $target'";
                      do_system "svn checkout file://${repository_dir}/svn_repo/$target $target";
                    }
    }
}

# operate on the named branch, creating it if necessary
sub branch {
    my ( $name, $operation ) = @_;
    chdir '..';
    if ( not -d $name ) {
        clone 'initial', $name;
    }
    chdir $name;
    $operation->();
    chdir '../initial';
}

# low-level operation to merge one repository into the current repository
sub perform_merge {
    my ($source) = @_;
    given($ENV{VCS}) {
        when('bzr') { system "bzr merge --show-base $source" }
        when('darcs') {
            system "darcs pull -a"
                 . " --mark-conflicts"
                 . " --no-set-default $source"
                 ;
        }
        when('git') {
            system "git pull --no-ff -Xignore-all-space -q $source master"
        }
        when('hg')  {
            system "hg pull $source";
            system "hg merge";
            system "hg commit -m 'merged from $source'";
        }
        when('svn') { my $current_path = cwd();
                      my $current_dir = qx"basename ${current_path}";
                      chomp $current_dir;
                      my $source_dir = qx"basename ${source}";
                      chomp $source_dir;
                      do_system "svn cp file://${repository_dir}/svn_repo/$source_dir file://${repository_dir}/svn_repo/$current_dir -m 'branching $source_dir into $current_dir'";
                      chdir "..";
                      do_system "svn checkout file://${repository_dir}/svn_repo/$current_dir $current_dir";
                      chdir $current_dir;
                    }
    }
}

sub merge_ok {
    my ( $x, $y ) = @_;
    chdir '..';

    # test merges in both directions (some VCS have asymmetric merges)
    for my $combo ( [$x,$y], [$y,$x] ) {
        my ($x,$y) = @$combo;
        my $repo_name = "merge-$y-into-$x";
        clone $x, $repo_name;
        chdir $repo_name;
        try {
            perform_merge("../$y");
            system("./run > obtained.txt");
            system("diff -u expected.txt obtained.txt");
            pass("merge $y into $x");
        }
        catch {
            fail("merge $y into $x");
        };
        chdir '..';
    }
}

# apply a sed script to a file, modifying it in-place
sub sed {
    my ($script, $file) = @_;
    system "sed -i -e '$script' $file";
}

# perform search and replace across an entire file
sub replace {
    my ( $old, $new, $file ) = @_;
    given($ENV{VCS}) {
        when('darcs') { system "darcs replace '$old' '$new' $file" }
        default       { sed "s/$old/$new/g", $file }
    }
}

# moves a file from one location to another (also used for renaming)
sub move {
    my ($old,$new) = @_;
    given($ENV{VCS}) {
        when('bzr')   { system "bzr   mv   $old $new" }
        when('darcs') { system "darcs move $old $new" }
        when('git')   { system "git   mv   $old $new" }
        when('hg')    { system "hg    mv   $old $new" }
        when('svn')   { do_system "svn   mv   $old $new" }
    }
}

1;
