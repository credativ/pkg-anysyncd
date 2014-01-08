use warnings;
use strict;

use Module::Build;
use File::Glob ':glob';

#We use eval because we only want the feature if
# Module::Build::Debian is actually installed.
BEGIN {
	eval 'use Module::Build::Debian';
}

use Module::Build::Debian;

my $build = Module::Build->new
(
	dist_name => 'Anysyncd',
	dist_abstract => 'Inotify based filesyncer',
	dist_author => 'Alexander Wirt <alexander.wirt@credativ.de>',
	dist_version_from => 'lib/Anysyncd/Daemon.pm',
	script_files => 'bin/',
    requires    => {
        'perl' => '5.10.0',
        'Moose' => 0,
        'MooseX::AttributeHelpers' => 0,
        'AnyEvent' => 0,
        'AnyEvent::Filesys::Notify' => 0,
        'Log::Log4perl' => 0,
        'Config::IniFiles' => 0,
        'AnyEvent::DateTime::Cron' => 0,
        'IPC::ShareLite' => 0,
        'File::Rsync' => 0,
    },
    #config_files => { map { $_ => $_ } bsd_glob('reports/*') },
    #install_path => { 'conf'  => '/etc/osfsum/reports' },
);


#$build->add_build_element ('config');

#$build->add_to_cleanup('docs/*.html', 'docs/*.pdf');
$build->create_build_script();
