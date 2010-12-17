
use strict;
use warnings;

BEGIN { require 5.006; }

use ExtUtils::MakeMaker 6.31;



my %WriteMakefileArgs = (
  'ABSTRACT' => 'Creates an evil twin of a CPAN distribution',
  'AUTHOR' => 'David Golden <dagolden@cpan.org>',
  'BUILD_REQUIRES' => {
    'File::Find' => '0',
    'File::Temp' => '0',
    'Test::More' => '0'
  },
  'CONFIGURE_REQUIRES' => {
    'ExtUtils::MakeMaker' => '6.31'
  },
  'DISTNAME' => 'Dist-Zilla-Plugin-Doppelgaenger',
  'EXE_FILES' => [],
  'LICENSE' => 'apache',
  'NAME' => 'Dist::Zilla::Plugin::Doppelgaenger',
  'PREREQ_PM' => {
    'Archive::Extract' => '0',
    'Dist::Zilla::File::InMemory' => '0',
    'Dist::Zilla::Role::AfterRelease' => '0',
    'Dist::Zilla::Role::FileGatherer' => '0',
    'Dist::Zilla::Role::FileMunger' => '0',
    'Dist::Zilla::Role::TextTemplate' => '0',
    'File::Find::Rule' => '0',
    'File::pushd' => '0',
    'HTTP::Tiny' => '0',
    'JSON' => '0',
    'Moose' => '0',
    'Moose::Autobox' => '0',
    'MooseX::Types::Path::Class' => '0',
    'MooseX::Types::Perl' => '0',
    'MooseX::Types::URI' => '0',
    'Path::Class' => '0',
    'Pod::Strip' => '0',
    'namespace::autoclean' => '0'
  },
  'VERSION' => '0.001',
  'test' => {
    'TESTS' => 't/*.t'
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



