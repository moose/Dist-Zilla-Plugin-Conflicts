use strict;
use warnings FATAL => 'all';

use File::pushd qw( pushd );
use Path::Tiny;

use Test::DZil;
use Test::Deep;
use Test::Differences;
use Test::Fatal;
use Test::More;
use if $ENV{AUTHOR_TESTING}, 'Test::Warnings';

my $tzil = Builder->from_config(
    { dist_root => 't/does-not-exist' },
    {
        add_files => {
            path(qw( source dist.ini )) => simple_ini(
                [ GatherDir => ],
                [ MakeMaker => ],
                [ ExecDir   => ],
                [ Prereqs   => { 'Foo' => '0' } ],
                [
                    'Conflicts' => {
                        -script     => 'script/dzt-conflicts',
                        'Module::X' => '0.02'
                    }
                ],
            ),
            path(qw( source lib DZT Sample.pm )) =>
                "package DZT::Sample;\n1;\n",
        },
    },
);

$tzil->chrome->logger->set_debug(1);
is(
    exception { $tzil->build() },
    undef,
    'build proceeds normally',
);

cmp_deeply(
    $tzil->distmeta,
    superhashof(
        {
            prereqs => {
                configure => {
                    requires => {
                        'Dist::CheckConflicts' => '0.02',
                        'ExtUtils::MakeMaker' =>
                            ignore,    # added by [MakeMaker]
                    }
                },
                runtime => {
                    requires => {
                        'Dist::CheckConflicts' => '0.02',
                        'Foo'                  => '0',
                    },
                },
            },
        }
    ),
    'prereqs are injected',
) or diag 'got distmeta: ', explain $tzil->distmeta();

my $build_dir = path( $tzil->tempdir )->child('build');

my $module_filename = $build_dir->child(qw( lib DZT Sample Conflicts.pm ));
ok( -e $module_filename, 'conflicts module created' );

my $module_content = $module_filename->slurp_utf8();
unlike(
    $module_content, qr/[^\S\n]\n/m,
    'no trailing whitespace in generated module'
);

my $version = Dist::Zilla::Plugin::Conflicts->VERSION() || '<self>';

my $expected_module_content = <<"MODULE_CONTENT";
package # hide from PAUSE
    DZT::Sample::Conflicts;

use strict;
use warnings;

# this module was generated with Dist::Zilla::Plugin::Conflicts $version

use Dist::CheckConflicts
    -dist      => 'DZT::Sample',
    -conflicts => {
        'Module::X' => '0.02',
    },
    -also => [ qw(
        Dist::CheckConflicts
        Foo
    ) ],

;

1;

# ABSTRACT: Provide information on conflicts for DZT::Sample
# Dist::Zilla: -PodWeaver
MODULE_CONTENT

eq_or_diff(
    $module_content,
    $expected_module_content,
    'module content looks good'
);

my $script_filename = $build_dir->child(qw( script dzt-conflicts ));
ok( -e $script_filename, 'conflicts script created' );

my $script_content = $script_filename->slurp_utf8();
unlike(
    $script_content,
    qr/[^\S\n]\n/m,
    'no trailing whitespace in generated script'
);

my $expected_script_content = <<"SCRIPT_CONTENT";
#!/usr/bin/perl

use strict;
use warnings;
# PODNAME: dzt-conflicts

# this script was generated with Dist::Zilla::Plugin::Conflicts $version

use Getopt::Long;
use DZT::Sample::Conflicts;

my \$verbose;
GetOptions( 'verbose|v' => \\\$verbose );

if (\$verbose) {
    DZT::Sample::Conflicts->check_conflicts;
}
else {
    my \@conflicts = DZT::Sample::Conflicts->calculate_conflicts;
    print "\$_\\n" for map { \$_->{package} } \@conflicts;
    exit \@conflicts;
}
SCRIPT_CONTENT

eq_or_diff(
    $script_content,
    $expected_script_content,
    'script content looks good'
);

{
    my $wd = pushd $build_dir;

    my @cmd = ( $^X, '-Ilib', $script_filename );
    is(
        system(@cmd),
        0,
        "no error running @cmd"
    );
}

done_testing;
