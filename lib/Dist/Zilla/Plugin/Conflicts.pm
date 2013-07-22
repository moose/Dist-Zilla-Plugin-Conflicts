package Dist::Zilla::Plugin::Conflicts;

use strict;
use warnings;
use namespace::autoclean;

use Dist::CheckConflicts 0.02 ();
use Dist::Zilla 4.0 ();
use Dist::Zilla::File::InMemory;
use Moose::Autobox 0.09;

use Moose;

with qw(
    Dist::Zilla::Role::FileGatherer
    Dist::Zilla::Role::InstallTool
    Dist::Zilla::Role::MetaProvider
    Dist::Zilla::Role::PrereqSource
    Dist::Zilla::Role::TextTemplate
);

has _conflicts => (
    is      => 'ro',
    isa     => 'HashRef',
    default => sub { {} },
);

has _script => (
    is        => 'ro',
    isa       => 'Str',
    predicate => '_has_script',
);

has _conflicts_module_name => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef,
    lazy     => 1,
    builder  => '_build_conflicts_module_name',
);

has _conflicts_module_path => (
    is       => 'ro',
    isa      => 'Str',
    init_arg => undef,
    lazy     => 1,
    builder  => '_build_conflicts_module_path',
);

sub BUILDARGS {
    my $class = shift;
    my %args = ref $_[0] ? %{ $_[0] } : @_;

    my $zilla = delete $args{zilla};
    my $name  = delete $args{plugin_name};
    my $bin   = delete $args{'-script'};

    return {
        zilla       => $zilla,
        plugin_name => $name,
        ( defined $bin ? ( _script => $bin ) : () ),
        _conflicts => \%args,
    };
}

sub _build_conflicts_module_name {
    my $self = shift;

    ( my $base = $self->zilla()->name() ) =~ s/-/::/g;

    return $base . '::Conflicts';
}

sub _build_conflicts_module_path {
    my $self = shift;

    my $path = join '/', split /-/, $self->zilla()->name();

    return "lib/$path/Conflicts.pm";
}

sub register_prereqs {
    my ($self) = @_;

    $self->zilla->register_prereqs(
        { phase => 'configure' },
        'Dist::CheckConflicts' => '0.02',
    );

    $self->zilla->register_prereqs(
        { phase => 'runtime' },
        'Dist::CheckConflicts' => '0.02',
    );

    for my $phase (qw( develop runtime )) {
        $self->zilla->register_prereqs(
            {
                phase => $phase,
                type  => 'conflicts',
            },
            %{ $self->_conflicts() },
        );
    }
}

sub gather_files {
    my $self = shift;

    $self->add_file(
        Dist::Zilla::File::InMemory->new(
            name    => $self->_conflicts_module_path(),
            content => $self->_generate_conflicts_module(),
        )
    );

    if ( $self->_has_script() ) {
        $self->add_file(
            Dist::Zilla::File::InMemory->new(
                name    => $self->_script(),
                content => $self->_generate_conflicts_script(),
            )
        );
    }

    return;
}

{
    my $conflicts_module_template = <<'EOF';
package # hide from PAUSE
    {{ $module_name }};

use strict;
use warnings;

use Dist::CheckConflicts
    -dist      => '{{ $dist_name }}',
    -conflicts => {
        {{ $conflicts_dump }},
    },
{{ $also_dump }}
;

1;

# ABSTRACT: Provide information on conflicts for {{ $dist_name }}
EOF

    sub _generate_conflicts_module {
        my $self = shift;

        my $conflicts = $self->_conflicts();

        my $conflicts_dump = join ",\n        ",
            map { qq['$_' => '$conflicts->{$_}'] } sort keys %{$conflicts};

        my $also_dump = join "\n        ", sort grep { $_ ne 'perl' }
            map { $_->required_modules() }
            $self->zilla()->prereqs()->requirements_for(qw(runtime requires));

        $also_dump
            = '    -also => [ qw(' . "\n"
            . '        '
            . $also_dump . "\n"
            . '    ) ],' . "\n"
            if length $also_dump;

        ( my $dist_name = $self->zilla()->name() ) =~ s/-/::/g;

        return $self->fill_in_string(
            $conflicts_module_template,
            {
                dist_name      => \$dist_name,
                module_name    => \( $self->_conflicts_module_name() ),
                conflicts_dump => \$conflicts_dump,
                also_dump      => \$also_dump,
            },
        );
    }
}

{
    # If dzil sees this string PODXXXX anywhere in this code it uses that as the
    # name for the module.
    my $podname_hack    = 'POD' . 'NAME';
    my $script_template = <<'EOF';
#!/usr/bin/perl

use strict;
use warnings;
# %s: {{ $filename }}

use Getopt::Long;
use {{ $module_name }};

my $verbose;
GetOptions( 'verbose|v' => \$verbose );

if ($verbose) {
    {{ $module_name }}->check_conflicts;
}
else {
    my @conflicts = {{ $module_name }}->calculate_conflicts;
    print "$_\n" for map { $_->{package} } @conflicts;
    exit @conflicts;
}
EOF
    $script_template = sprintf( $script_template, $podname_hack );

    sub _generate_conflicts_script {
        my $self = shift;

        ( my $filename = $self->_script() ) =~ s+^.*/++;

        return $self->fill_in_string(
            $script_template,
            {
                filename    => \$filename,
                module_name => \( $self->_conflicts_module_name() ),
            },
        );
    }
}

# XXX - this should really be a separate phase that runs after InstallTool -
# until then, all we can do is die if we are run too soon
sub setup_installer {
    my $self = shift;

    my $found_installer;
    for my $file ( $self->zilla()->files()->flatten() ) {
        if ( $file->name() =~ /Makefile\.PL$/ ) {
            $self->_munge_makefile_pl($file);
            $found_installer++;
        }
        elsif ( $file->name() =~ /Build\.PL$/ ) {
            $self->_munge_build_pl($file);
            $found_installer++;
        }
    }

    return if $found_installer;

    $self->log_fatal( 'No Makefile.PL or Build.PL was found.'
            . ' [Conflicts] should appear in your dist.ini'
            . ' after [MakeMaker] or [ModuleBuild]!' );
}

sub _munge_makefile_pl {
    my $self     = shift;
    my $makefile = shift;

    my $content = $makefile->content();

    $content =~ s/(use ExtUtils::MakeMaker.*)/$1\ncheck_conflicts();/;
    $content .= "\n" . $self->_check_conflicts_sub();

    $makefile->content($content);

    return;
}

sub _munge_build_pl {
    my $self  = shift;
    my $build = shift;

    my $content = $build->content();

    $content =~ s/(use Module::Build.*)/$1\ncheck_conflicts();/;
    $content .= "\n" . $self->_check_conflicts_sub();

    $build->content($content);

    return;
}

{
    my $check_conflicts_template = <<'CC_SUB';
sub check_conflicts {
    if ( eval { require '{{ $conflicts_module_path }}'; 1; } ) {
        if ( eval { {{ $conflicts_module_name }}->check_conflicts; 1 } ) {
            return;
        }
        else {
            my $err = $@;
            $err =~ s/^/    /mg;
            warn "***\n$err***\n";
        }
    }
    else {
        print <<'EOF';
***
{{ $warning }}
***
EOF
    }

    return if $ENV{AUTOMATED_TESTING} || $ENV{NONINTERACTIVE_TESTING};

    # More or less copied from Module::Build
    return if $ENV{PERL_MM_USE_DEFAULT};
    return unless -t STDIN && ( -t STDOUT || !( -f STDOUT || -c STDOUT ) );

    sleep 4;
}
CC_SUB

    sub _check_conflicts_sub {
        my $self = shift;

        my $warning;
        if ( $self->_has_script() ) {
            ( my $filename = $self->_script() ) =~ s+^.*/++;
            $warning = <<"EOF";
    Your toolchain doesn't support configure_requires, so Dist::CheckConflicts
    hasn't been installed yet. You should check for conflicting modules
    manually using the '$filename' script that is installed with
    this distribution once the installation finishes.
EOF
        }
        else {
            my $mod = $self->_conflicts_module_name();
            $warning = <<"EOF";
    Your toolchain doesn't support configure_requires, so Dist::CheckConflicts
    hasn't been installed yet. You should check for conflicting modules
    manually by examining the list of conflicts in $mod once the installation
    finishes.
EOF
        }

        chomp $warning;

        return $self->fill_in_string(
            $check_conflicts_template,
            {
                conflicts_module_path => \( $self->_conflicts_module_path() ),
                conflicts_module_name => \( $self->_conflicts_module_name() ),
                warning               => \$warning,
            },
        );
    }
}

sub metadata {
    my $self = shift;

    return { x_breaks => $self->_conflicts() };
}

=begin Pod::Coverage

  gather_files
  metadata
  register_prereqs
  setup_installer

=end Pod::Coverage

=cut

__PACKAGE__->meta->make_immutable;

1;

# ABSTRACT: Declare conflicts for your distro

__END__

=head1 SYNOPSIS

In your F<dist.ini>:

  [Conflicts]
  Foo::Bar = 0.05
  Thing    = 2

=head1 DESCRIPTION

This module lets you declare conflicts on other modules (usually dependencies
of your module) in your F<dist.ini>.

Declaring conflicts does several thing to your distro.

First, it generates a module named something like
C<Your::Distro::Conflicts>. This module will use L<Dist::CheckConflicts> to
declare and check conflicts. The package name will be obscured from PAUSE by
putting a newline after the C<package> keyword.

All of your runtime prereqs will be passed in the C<-also> parameter to
L<Dist::CheckConflicts>.

Second, it adds code to your F<Makefile.PL> or F<Build.PL> to load the
generated module and print warnings if conflicts are detected.

Third, it adds "conflicts" entries to the develop and runtime prereqs, per
CPAN Meta Spec (https://metacpan.org/module/CPAN::Meta::Spec#Prereq-Spec).

Finally, it adds the conflicts to the F<META.json> and/or F<META.yml> files
under the "x_breaks" key.

=head1 USAGE

Using this module is simple, add a "[Conflicts]" section and list each module
you conflict with:

  [Conflicts]
  Module::X = 0.02

The version listed is the last version that I<doesn't> work. In other words,
any version of C<Module::X> greater than 0.02 should work with this release.

The special key C<-script> can also be set, and given the name of a script to
generate, as in:

  [Conflicts]
  -script   = bin/foo-conflicts
  Module::X = 0.02

This script will be installed with your module, and can be run to check for
currently installed modules which conflict with your module. This allows users
an easy way to fix their conflicts - simply run a command such as
C<foo-conflicts | cpanm> to bring all of your conflicting modules up to date.

B<Note:> Currently, this plugin only works properly if it is listed in your
F<dist.ini> I<after> the plugin which generates your F<Makefile.PL> or
F<Build.PL>. This is a limitation of L<Dist::Zilla> that will hopefully be
addressed in a future release.

=head1 SUPPORT

Please report any bugs or feature requests to
C<bug-dist-zilla-plugin-conflicts@rt.cpan.org>, or through the web interface
at L<http://rt.cpan.org>. I will be notified, and then you'll automatically be
notified of progress on your bug as I make changes.

=head1 DONATIONS

If you'd like to thank me for the work I've done on this module, please
consider making a "donation" to me via PayPal. I spend a lot of free time
creating free software, and would appreciate any support you'd care to offer.

Please note that B<I am not suggesting that you must do this> in order for me
to continue working on this particular software. I will continue to do so,
inasmuch as I have in the past, for as long as it interests me.

Similarly, a donation made in this way will probably not make me work on this
software much more, unless I get so many donations that I can consider working
on free software full time, which seems unlikely at best.

To donate, log into PayPal and send money to autarch@urth.org or use the
button on this page: L<http://www.urth.org/~autarch/fs-donation.html>

=cut
