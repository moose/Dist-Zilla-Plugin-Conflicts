package Dist::Zilla::Plugin::Conflicts;

use strict;
use warnings;

use Dist::CheckConflicts 0.01 ();
use Moose::Autobox 0.09;

use Moose;

with qw(
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
}

# This should be done in the file gatherer stage, but that happens _before_
# prereqs are registered, and we can't generate our conflict module until
# after we know all the prereqs.
after register_prereqs => sub {
    my $self = shift;

    $self->add_file( $self->_build_conflicts_file() );

    $self->add_file( $self->_build_script() )
        if $self->_has_script();

    return;
};

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
EOF

sub _build_conflicts_file {
    my $self = shift;

    my $conflicts = $self->_conflicts();

    my $conflicts_dump = join ",\n        ",
        map {qq['$_' => '$conflicts->{$_}']} sort keys %{$conflicts};

    my $also_dump = join "\n        ",
        sort grep { $_ ne 'perl' }
        map { $_->required_modules() }
        $self->zilla()->prereqs()->requirements_for(qw(runtime requires));

    $also_dump
        = '    -also => [ qw(' . "\n"
        . '        '
        . $also_dump . "\n"
        . '    ) ],' . "\n"
        if length $also_dump;

    ( my $dist_name = $self->zilla()->name() ) =~ s/-/::/g;

    my $content = $self->fill_in_string(
        $conflicts_module_template, {
            dist_name      => \$dist_name,
            module_name    => \( $self->_conflicts_module_name() ),
            conflicts_dump => \$conflicts_dump,
            also_dump      => \$also_dump,
        },
    );

    return Dist::Zilla::File::InMemory->new(
        name    => $self->_conflicts_module_path(),
        content => $content,
    );
}

my $script_template = <<'EOF';
#!/usr/bin/perl

use strict;
use warnings;
# PODNAME: {{ $filename }}

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

sub _build_script {
    my $self = shift;

    ( my $filename = $self->_script() ) =~ s+^.*/++;
    my $content = $self->fill_in_string(
        $script_template, {
            filename    => \$filename,
            module_name => \( $self->_conflicts_module_name() ),
        },
    );

    return Dist::Zilla::File::InMemory->new(
        name    => $self->_script(),
        content => $content,
    );
}

# XXX - this should really be a separate phase that runs after InstallTool
sub setup_installer {
    my $self = shift;

    for my $file ( $self->zilla()->files()->flatten() ) {
        if ( $file->name() =~ /Makefile\.PL$/ ) {
            $self->_munge_makefile_pl($file);
        }
        elsif ( $file->name() =~ /Build\.PL$/ ) {
            $self->_munge_build_pl($file);
        }
    }

    return;
};

sub _munge_makefile_pl {
    my $self = shift;
    my $makefile = shift;

    my $content = $makefile->content();

    $content =~ s/(use ExtUtils::MakeMaker.*)/$1\ncheck_conflicts();/;
    $content .= "\n" . $self->_check_conflicts_sub();

    $makefile->content($content);

    return;
}

sub _munge_build_pl {
    my $self = shift;
    my $build = shift;

    my $content = $build->content();

    $content =~ s/(use Module::Build.*)/$1\ncheck_conflicts();/;
    $content .= "\n" . $self->_check_conflicts_sub();

    $build->content($content);

    return;
}

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
        $check_conflicts_template, {
            conflicts_module_path => \( $self->_conflicts_module_path() ),
            conflicts_module_name => \( $self->_conflicts_module_name() ),
            warning               => \$warning,
        },
    );
}

sub metadata {
    my $self = shift;

    return { x_conflicts => $self->_conflicts() };
}

no Moose;

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

Finally, it adds the conflicts to the F<META.json> and/or F<META.yml> files
under the "x_conflicts" key.

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
