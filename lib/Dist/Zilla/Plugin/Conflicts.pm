package Dist::Zilla::Plugin::Conflicts;

use strict;
use warnings;

use Dist::CheckConflicts 0.01 ();
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

    return {
        zilla       => $zilla,
        plugin_name => $name,
        _conflicts  => \%args,
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
        'Dist::CheckConflicts' => '0.01',
    );
}

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
;

1;
EOF

sub gather_files {
    my $self = shift;

    my $conflicts = $self->_conflicts();

    my $conflicts_dump = join ",\n        ",
        map {qq['$_' => '$conflicts->{$_}']} sort keys %{$conflicts};

    ( my $dist_name = $self->zilla()->name() ) =~ s/-/::/g;

    my $content = $self->fill_in_string(
        $conflicts_module_template, {
            dist_name      => \$dist_name,
            module_name    => \( $self->_conflicts_module_name() ),
            conflicts_dump => \$conflicts_dump,
        },
    );

    my $file = Dist::Zilla::File::InMemory->new(
        name    => $self->_conflicts_module_path(),
        content => $content,
    );

    $self->add_file($file);
    return;
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
    Your toolchain doesn't support configure_requires, so Dist::CheckConflicts
    hasn't been installed yet. You should check for conflicting modules
    manually using the 'package-stash-conflicts' script that is installed with
    this distribution once the installation finishes.
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

    return $self->fill_in_string(
        $check_conflicts_template, {
            conflicts_module_path => \( $self->_conflicts_module_path() ),
            conflicts_module_name => \( $self->_conflicts_module_name() ),
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
