use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    NAME		=> 'Apache::MP3',
    AUTHOR              => 'Lincoln Stein <lstein@cshl.org>',
    ABSTRACT            => 'mod_perl class for generating browsable MP3 directory lists',
    ABSTRACT_FROM       => 'MP3.pm',
    VERSION             => '3.04',
    PREREQ_PM		=> {
			    MP3::Info  => 0.8,
			    Apache     => 1.14,
			    Audio::Wav => 0.02,
			    Ogg::Vorbis =>0.02,
			    Locale::Maketext => 1.03,
			   }, # e.g., Module::Name => 1.1
);

1;
