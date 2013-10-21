package Sync::Daemon;

=head1 NAME

Sync::Daemon - Daemonizing for Sync

=head1 SYNOPSIS

    use Sync::Daemon;
    my $daemon = Sync::Daemon->new_with_options();
    my ($command) = @{$daemon->extra_argv};

    $daemon->start   if $command eq 'start';
    $daemon->status  if $command eq 'status';
    $daemon->restart if $command eq 'restart';
    $daemon->stop    if $command eq 'stop';

    exit($daemon->exit_code);

=head1 DESCRIPTION

This module takes care about daemonizing the stats daemon. It uses
L<MooseX::Daemonize> for all the dirty work.

The following functions provided by L<MooseX::Daemonize> are hidden
to the Getopt Interface:

=over 12

=item C<MooseX::Daemonize::pidbase>

=item C<MooseX::Daemonize::no_double_fork>

=item C<MooseX::Daemonize::ignore_zombies>

=item C<MooseX::Daemonize::progname>

=item C<MooseX::Daemonize::dont_close_all_files>

=item C<MooseX::Daemonize::basedir>

=back

=head2 Configuration File

None yet

=head2 Methods

=over 12

=cut

use strict;
use warnings;

use v5.10;
use Moose;
with qw(MooseX::Daemonize);
use MooseX::AttributeHelpers;

use AnyEvent;
use AnyEvent::Filesys::Notify;
use Log::Log4perl;
use Config::IniFiles;

my $VERSION = '0.1';

=item C<log>

$self->log is a L<Log::Log4perl::Logger> object

=cut

has log =>
    ( is => 'rw', isa => 'Log::Log4perl::Logger', traits => ['NoGetopt'] );

=item C<logfile> 

$self->logfile allows to set the logfile, this can't be changed after the
object
is fully initialized (in that case after C<$self->log> is used for the first
time

=cut

has logfile => (
    is            => 'rw',
    isa           => 'Str',
    builder       => '_build_logfile',
    lazy          => 1,
    documentation => qq { logfile (default: /var/log/Sync.log) }
);

=item C<loglevel> 

$self->loglevel allows to set the loglevel, this can't be changed after the object
is fully initialized (in that case after C<$self->log> is used for the first
time

=cut

has loglevel => (
    is            => 'rw',
    isa           => 'Str',
    builder       => '_build_loglevel',
    lazy          => 1,
    documentation => qq { log4perl compatible loglevel (default: DEBUG) }
);

=item C<configfile> 

$self->configfile represents the configurationfile, it defaults to /etc/sync.ini

=cut

has configfile => (
    is            => 'rw',
    isa           => 'Str',
    default       => '/etc/sync.ini',
    documentation => qq { configfile for Sync, defaults to '/etc/sync.ini' }
);

=item C<config> 

$self->config the Config::IniFiles configuration object

=cut

has config => (
    is            => 'rw',
    isa           => 'Config::IniFiles',
    documentation => qq { the 'Config::IniFiles' configobject }
);

#hide some stuff from the commandline
has '+pidbase'        => ( traits => ['NoGetopt'] );
has '+no_double_fork' => ( traits => ['NoGetopt'] );
has '+ignore_zombies' => ( traits => ['NoGetopt'] );
has '+progname'       => ( traits => ['NoGetopt'] );

#has '+dont_close_all_files' => ( traits => ['NoGetopt'] );
has '+basedir' => ( traits => ['NoGetopt'] );

has 'files' => (
    metaclass => 'Collection::Array',
    is        => 'ro',
    isa       => 'ArrayRef',
    default   => sub { [] },
    provides  => {
        'push'   => 'add_files',
        'delete' => 'delete_files',
    }
);

sub _build_loglevel {
    my $self = shift;
    return $self->config->val( 'global', 'loglevel' ) || 'DEBUG';
}

sub _build_logfile {
    my $self = shift;

    my $logfile = $self->config->val( 'global', 'logfile' )
        || '/var/log/Sync.log';
    return $logfile;
}

sub _logging_configuration {
    my $self     = shift;
    my $logfile  = $self->logfile;
    my $loglevel = $self->loglevel;
    my $config   = \qq {
    log4perl.rootLogger= $loglevel, Logfile
    log4perl.appender.Logfile = Log::Log4perl::Appender::File
    log4perl.appender.Logfile.filename = $logfile
    log4perl.appender.Logfile.layout = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Logfile.layout.ConversionPattern = %d %p %c %m%n
    };
    return $config;
}

sub BUILD {
    my $self = shift;

    local $Carp::CarpLevel = $Carp::CarpLevel + 1;

    my $filename = $self->configfile;
    if ( !-f $filename ) {
        print STDERR "Configuration file \"$filename\" does not exist\n";
        exit 1;
    } else {
        my $cfg = Config::IniFiles->new( -file => $filename, );
        if ( !$cfg ) {
            confess "Could not read $filename: "
                . join( ",", @Config::IniFiles::errors );
        }
        $self->config($cfg);
    }
}

before shutdown => sub {
    my $self = shift;
    Log::Log4perl->init( $self->_logging_configuration );
    $self->log( Log::Log4perl->get_logger() );
    $self->log->info('Daemon shutting down');
};

before stop => sub {
    my $self = shift;
    Log::Log4perl->init( $self->_logging_configuration );
    $self->log( Log::Log4perl->get_logger() );
    $self->log->info('Daemon shutting down');
};

after restart => sub {
    my $self = shift;
    Log::Log4perl->init( $self->_logging_configuration );
    $self->log( Log::Log4perl->get_logger() );
    $self->log->info('Daemon restarted');
};

after start => sub {
    my $self = shift;

    return unless $self->is_daemon;
    $0 = 'Sync (manager process)';

    Log::Log4perl->init( $self->_logging_configuration );

    $self->log( Log::Log4perl->get_logger() );

    foreach my $section ( $self->config->Sections() ) {
        next if $section eq 'global';
        my $handler = $self->config->val( $section, 'handler' );
        if ( !$handler ) {
            $self->log->error(
                "Section \"$section\" has no configured handler");
            next;
        }

        #build configuration for the handler

        my $config_for_handler;
        foreach my $key ( $self->config->Parameters($section) ) {
            $config_for_handler->{$key} =
                $self->config->val( $section, $key );
        }
        $config_for_handler->{name} = $section;

        my $obj =
            $self->_load( $section, $handler, "new",
            config => $config_for_handler )
            || next;
        $self->{'handlers'}->{$section}->{'obj'} = $obj;

        $self->log->info("Added $handler as handler for $section");

        my $watcher = $self->config->val( $section, 'watcher' );
        if ( !$watcher ) {
            $self->error("No watcher found for $section");
            next;
        }
        my $filter = $self->config->val( $section, 'filter' )
            || '\.(swp|tmp)$';

        my $notifier = AnyEvent::Filesys::Notify->new(
            dirs   => [$watcher],
            filter => sub { shift !~ /$filter/ },
            cb     => sub {
                $self->process( $section, @_ );
            }
        );
        if ($notifier) {
            $self->log->info("Watcher added for $section");
        }
    }

    my $w = AnyEvent->condvar;  # stores whether a condition was flagged
    $w->recv;                   # enters "main loop" till $condvar gets ->send
};

sub process {
    my $self    = shift;
    my $section = shift;
    foreach my $event (@_) {
        $self->{'handlers'}->{$section}->{'obj'}->add_files( $event->path );
    }
}

sub _load {

    my ( $self, $section, $module, $constructor, @args ) = @_;

    eval "require $module";

    if ($@) {
        $self->log->error(
            "Could not load module $module for section $section: $@");
        return undef;
    }
    my $obj;
    eval { $obj = $module->$constructor(@args); };
    if ($@) {
        $self->log->error(
            "Could not instantiate module $module for section $section: $@");
        return undef;
    }
    return $obj;
}

=back

=head1 LICENSE

This is released under the FIXME
License. See B<FIXME>.

=head1 AUTHOR

Alexander Wirt <alexander.wirt@credativ.de>

=cut

__PACKAGE__->meta->make_immutable;

__END__

# vim: syntax=perl sw=4 ts=4 et shiftround

