use strict;
use warnings;

package Dist::Zilla::Plugin::Doppelgaenger;
# ABSTRACT: Creates an evil twin of a CPAN distribution
our $VERSION = '0.005'; # VERSION

use Moose;
use Moose::Autobox;
use MooseX::Types::Path::Class qw(Dir File);
use MooseX::Types::URI qw(Uri);
use MooseX::Types::Perl qw(ModuleName);
with 'Dist::Zilla::Role::FileGatherer';
with 'Dist::Zilla::Role::TextTemplate';
with 'Dist::Zilla::Role::FileMunger';   # for Changes
with 'Dist::Zilla::Role::AfterRelease'; # for Changes

use Dist::Zilla::File::InMemory;
use File::Find::Rule;
use File::pushd qw/tempd/;
use Path::Class;
use Pod::Strip;
use Archive::Extract;
use HTTP::Tiny;
use JSON;

use namespace::autoclean;

#--------------------------------------------------------------------------#
# public attributes
#--------------------------------------------------------------------------#


has source_module => (
    is       => 'ro',
    isa      => ModuleName,
    required => 1,
);


has new_name => (
    is       => 'ro',
    isa      => ModuleName,
    lazy     => 1,
    required => 1,
    builder  => '_build_new_name',
);

sub _build_new_name {
    my ($self) = shift;
    my $name = $self->zilla->name;
    $name =~ s{-}{::}g;
    return $name;
}


has cpan_mirror => (
    is      => 'ro',
    isa     => Uri,
    coerce  => 1,
    default => 'http://www.cpan.org/'
);


has strip_version => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);


has strip_pod => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);


has changes_file => (
    is      => 'ro',
    isa     => 'Str',
    default => 'Changes',
);


has update_changes_file => (
    is      => 'ro',
    isa     => 'Bool',
    default => 1,
);

#--------------------------------------------------------------------------#
# private
#--------------------------------------------------------------------------#

has _cpanidx => (
    is      => 'ro',
    isa     => 'Str',
    default => 'http://cpanidx.org/',
);

has _distfile => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_distfile',
);

sub _build_distfile {
    my ($self) = @_;
    my $mod = $self->source_module;
    my $uri = $self->_cpanidx . join( "/", qw/cpanidx json mod/, $mod );
    my $response = HTTP::Tiny->new->get( "$uri", { headers => { accept => '*' }, } );
    die "Could not find $mod via $uri: $response->{content}\n"
      unless $response->{success};

    my $meta = decode_json( $response->{content} )->[0];

    return $meta->{dist_file};
}

has _short_distfile => (
    is      => 'ro',
    isa     => 'Str',
    lazy    => 1,
    builder => '_build_short_distfile',
);

sub _build_short_distfile {
    my ($self) = @_;
    my $distfile = $self->_distfile;
    $distfile =~ s{./../}{};
    return $distfile;
}

#--------------------------------------------------------------------------#
# methods
#--------------------------------------------------------------------------#

sub gather_files {
    my ($self) = @_;

    my $distfile = $self->_distfile
      or die "Could not find distfile for " . $self->source_module . "\n";

    $self->log( [ 'Cloning files from %s', $self->_short_distfile ] );
    my $wd      = tempd;
    my $tarball = $self->_download($distfile);
    my $ae      = Archive::Extract->new( archive => $tarball );
    $ae->extract
      or die "Couldn't unpack $tarball: " . $ae->error;

    my ($extracted) = grep { -d } dir($wd)->children;
    die "Couldn't find untarred folder for $tarball\n"
      unless $extracted;

    FILE: for my $filename ( grep { -f } @{ $ae->files } ) {
        my $file = file($filename)->relative($extracted);
        next FILE if $file->basename =~ qr/^\./;
        next FILE if grep { /^\.[^.]/ } $file->dir->dir_list;
        next FILE unless $file =~ /^(?:lib|t|bin)\//;
        $self->log_debug( [ 'selected %s', $filename ] );
        my $dz_file = $self->_file_from_filename( $filename, $file );
        $self->_munge_filename($dz_file);
        $self->_munge_file($dz_file);
        $self->_strip_version($dz_file);
        $self->_strip_pod($dz_file);
        $self->add_file($dz_file);
    }

    return;
}

sub _munge_filename {
    my ( $self, $file ) = @_;

    my $old_name = $self->source_module;
    my $new_name = $self->new_name;
    s{::}{/}g for $new_name, $old_name;

    ( my $new_filename = $file->name ) =~ s{$old_name}{$new_name};
    if ( $new_filename ne $file->name ) {
        $self->log_debug( [ 'renaming %s to %s', $file->name, $new_filename ] );
        $file->name($new_filename);
    }
    return;
}

sub _munge_file {
    my ( $self, $file ) = @_;

    my $old_name = $self->source_module;
    my $new_name = $self->new_name;

    ( my $old_pm = $old_name ) =~ s{::}{/}g;
    $old_pm .= ".pm";
    ( my $new_pm = $new_name ) =~ s{::}{/}g;
    $new_pm .= ".pm";

    $self->log_debug( [ 'updating contents of %s', $file->name ] );

    my $content = $file->content;
    $content =~ s{$old_name}{$new_name}g;
    $content =~ s{\Q$old_pm\E}{$new_pm}g;
    $file->content($content);
}

# match a line that appears to assign to a $VERSION variable
# it's a bit more liberal on package names that Perl allows, oh, well
my $version_re = qr/\$(?:(?i)[a-z0-9]+::){0,}VERSION\s*=\s*/;

sub _strip_version {
    my ( $self, $file ) = @_;
    return unless $self->strip_version;
    return
      unless $file->name =~ m{\.pm\z}
      or $file->content =~ /\A#!.*?perl/;
    $self->log_debug( [ 'stripping VERSION from %s', $file->name ] );
    # replace
    my @lines =
      map { /$version_re/ ? '; # original $VERSION removed by Doppelgaenger' : $_ }
      split "\n",
      $file->content;
    $file->content( join( "\n", @lines ) . "\n" );
}

sub _strip_pod {
    my ( $self, $file ) = @_;
    return unless $self->strip_pod;
    return unless $file->name =~ m{\.p(?:m|od)\z};
    $self->log_debug( [ 'stripping pod from %s', $file->name ] );
    my $p = Pod::Strip->new;
    my $podless;
    $p->output_string( \$podless );
    $p->parse_string_document( $file->content );
    $file->content($podless);
}

sub munge_file {
    my ( $self, $file ) = @_;
    $self->_munge_changes($file) if $file->name eq $self->changes_file;
}

sub _munge_changes {
    my ( $self, $file ) = @_;
    return unless $self->update_changes_file;

    my $content  = $file->content;
    my $distfile = $self->_short_distfile;
    my $delim    = $self->delim;

    $content =~ s{ (\Q$delim->[0]\E \s* \$NEXT \s* \Q$delim->[1]\E) }
               {$1\n\n  - Generated from $distfile}xs;

    $file->content($content);
}

sub after_release {
    my ($self) = @_;
    return unless $self->update_changes_file && -e $self->changes_file;

    my $file = Dist::Zilla::File::OnDisk->new( { name => $self->changes_file, } );
    $self->_munge_changes($file);
    my $content = $file->content;

    my $filename = $self->changes_file;

    $self->log( [ 'updating contents of %s on disk', $filename ] );

    # and finally rewrite the changelog on disk
    open my $out_fh, '>', $filename
      or Carp::croak("can't open $filename for writing: $!");

    # Win32.
    binmode $out_fh, ':raw';
    print $out_fh $content or Carp::croak("error writing to $filename: $!");
    close $out_fh or Carp::croak("error closing $filename: $!");
}

sub _download {
    my ( $self, $distfile ) = @_;
    ( my $tarball = $distfile ) =~ s{\A.*/([^/]+)\z}{$1};
    my $uri = $self->cpan_mirror . join( "/", qw/authors id/, $distfile );
    my $response = HTTP::Tiny->new->mirror( "$uri", $tarball );
    die "Could not download $uri\n"
      unless $response->{success};
    return $tarball;
}

sub _file_from_filename {
    my ( $self, $filename, $rel_name ) = @_;

    my $file = Dist::Zilla::File::InMemory->new(
        {
            name => "$rel_name",
            mode => ( stat $filename )[2] & 0755, ## no critic: kill world-writeability
            content => do { local ( @ARGV, $/ ) = "$filename"; <> },
        }
    );
    return $file;
}

__PACKAGE__->meta->make_immutable;
1;


# vim: ts=4 sts=4 sw=4 et:

__END__

=pod

=encoding utf-8

=head1 NAME

Dist::Zilla::Plugin::Doppelgaenger - Creates an evil twin of a CPAN distribution

=head1 VERSION

version 0.005

=head1 SYNOPSIS

  [Doppelgaenger]
  source_module = Foo::Bar
  strip_pod = 1

=head1 DESCRIPTION

This L<Dist::Zilla> plugin creates a new CPAN distribution with a new name
based on the latest stable distribution of a source module.

Please do not do this without the permission of the authors or maintainers
of the source.

If the Changes files is flagged to be updated, you must have C<{{$NEXT}}> in
your Changes files and use the C<NextRelease> plugin.  The source distribution
will be added on a line in the Changes file after C<{{$NEXT}}>.  After release,
your original Changes file might look something like this:

  0.001     2010-12-17 08:37:08 EST5EDT

    - Generated from AUTHOR/Foo-Bar-1.23.tar.gz

If you strip Pod, you may with to explore replacing it with new Pod using
the L<Dist::Zilla::Plugin::AppendExternalData> plugin.

=head1 ATTRIBUTES

=head2 source_module (REQUIRED)

The name of a CPAN module to imitate.  E.g. Foo::Bar

=head2 new_name

The new name to use in place of the source name.  Defaults to
the converted form of the distribution name.

=head2 cpan_mirror

This is a URI to a CPAN mirror.  It must be an 'http' URI.
Defaults to C<http://www.cpan.org/>

=head2 strip_version

Boolean for whether any assignments to C<$VERSION> should be stripped out of
the source.  This is a crude hack and acts by killing a line of code containing
such assignments.  This obviously may not work in all cases and should be used
with caution.  Default is false.

=head2 strip_pod

Boolean for whether Pod should be stripped when copying from source.
Default is false.

=head2 changes_file

Name of change log file.  Defaults to 'Changes'.

=head2 update_changes_file

Boolean for whether change log should be updated with the
source distribution when built. Default is true.

=for Pod::Coverage gather_files munge_file after_release

=for :stopwords cpan testmatrix url annocpan anno bugtracker rt cpants kwalitee diff irc mailto metadata placeholders metacpan

=head1 SUPPORT

=head2 Bugs / Feature Requests

Please report any bugs or feature requests through the issue tracker
at L<https://github.com/dagolden/Dist-Zilla-Plugin-Doppelgaenger/issues>.
You will be notified automatically of any progress on your issue.

=head2 Source Code

This is open source software.  The code repository is available for
public review and contribution under the terms of the license.

L<https://github.com/dagolden/Dist-Zilla-Plugin-Doppelgaenger>

  git clone https://github.com/dagolden/Dist-Zilla-Plugin-Doppelgaenger.git

=head1 AUTHOR

David Golden <dagolden@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2010 by David Golden.

This is free software, licensed under:

  The Apache License, Version 2.0, January 2004

=cut
