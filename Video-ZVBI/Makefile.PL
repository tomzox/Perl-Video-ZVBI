use ExtUtils::MakeMaker;

WriteMakefile(
    'NAME'	   => 'Video::Capture::ZVBI',
    'VERSION_FROM' => 'ZVBI.pm',
    'LIBS'         => [ "-lzvbi" ],
);
