use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.
WriteMakefile(
    'NAME'	=> 'Apache::MP3',
    'VERSION_FROM' => 'MP3.pm',
    'LIBS'	=> [''],
    'DEFINE'	=> '',  
    'INC'	=> '',  
     PREREQ_PM    => { MP3::Info     => 0 },
);
