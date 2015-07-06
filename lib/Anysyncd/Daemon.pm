package Anysyncd::Daemon;

=head1 NAME

Anysyncd::Daemon - Daemonizing for anysyncd

=head1 SYNOPSIS

    use Anysyncd::Daemon;
    my $daemon = Anysyncd::Daemon->new_with_options();
    my ($command) = @{$daemon->extra_argv};

    $daemon->start   if $command eq 'start';
    $daemon->status  if $command eq 'status';
    $daemon->restart if $command eq 'restart';
    $daemon->stop    if $command eq 'stop';

    exit($daemon->exit_code);

=head1 DESCRIPTION

This module takes care of daemonizing the anysyncd daemon. It uses
L<MooseX::Daemonize> for all the dirty work.

The following functions provided by L<MooseX::Daemonize> are hidden to the
Getopt Interface:

=over 12

=item C<MooseX::Daemonize::pidbase>

=item C<MooseX::Daemonize::no_double_fork>

=item C<MooseX::Daemonize::ignore_zombies>

=item C<MooseX::Daemonize::progname>

=item C<MooseX::Daemonize::dont_close_all_files>

=item C<MooseX::Daemonize::basedir>

=back

=head2 Configuration File

See the configfile and config methods below.

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
use Log::Log4perl;
use Config::IniFiles;
use Data::Dumper;
use Carp qw(croak);

my $VERSION = '1.10.1';

=item C<log>

$self->log is a L<Log::Log4perl::Logger> object

=cut

has log =>
    ( is => 'rw', isa => 'Log::Log4perl::Logger', traits => ['NoGetopt'] );

=item C<logfile>

$self->logfile allows to set the logfile, this can't be changed after the object
is fully initialized (in that case after C<$self->log> is used for the first
time

=cut

has logfile => (
    is            => 'rw',
    isa           => 'Str',
    builder       => '_build_logfile',
    lazy          => 1,
    documentation => qq { logfile (default: /var/log/anysyncd.log) }
);

=item C<loglevel>

$self->loglevel allows to set the loglevel, this can't be changed after the
object is fully initialized (in that case after C<$self->log> is used for the
first time

=cut

has loglevel => (
    is            => 'rw',
    isa           => 'Str',
    builder       => '_build_loglevel',
    lazy          => 1,
    documentation => qq { log4perl compatible loglevel (default: INFO) }
);

=item C<configfile>

$self->configfile represents the configurationfile, it defaults to
/etc/anysyncd/anysyncd.ini

=cut

has configfile => (
    is      => 'rw',
    isa     => 'Str',
    default => '/etc/anysyncd/anysyncd.ini',
    documentation =>
        qq { configfile for anysyncd, defaults to '/etc/anysyncd/anysyncd.ini' }
);

=item C<config>

$self->config the Config::IniFiles configuration object

=cut

has config => (
    is            => 'rw',
    isa           => 'Config::IniFiles',
    documentation => qq { the 'Config::IniFiles' configobject }
);

# hide some stuff from the commandline
has '+pidbase'        => ( traits => ['NoGetopt'] );
has '+no_double_fork' => ( traits => ['NoGetopt'] );
has '+ignore_zombies' => ( traits => ['NoGetopt'] );
has '+progname'       => ( traits => ['NoGetopt'] );

# has '+dont_close_all_files' => ( traits => ['NoGetopt'] );
has '+basedir' => ( traits => ['NoGetopt'] );

sub _build_loglevel {
    my $self = shift;
    return $self->config->val( 'global', 'loglevel' ) || 'INFO';
}

sub _build_logfile {
    my $self = shift;

    my $logfile = $self->config->val( 'global', 'logfile' )
        || '/var/log/anysyncd.log';
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
    log4perl.appender.Logfile.layout.ConversionPattern = %d %p %c[%P] %m%n
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

    my $statedir = "/var/lib/anysyncd";
    if ( !-d $statedir ) {
        mkdir( $statedir, 0700 ) or croak("Failed to create $statedir: $!");
    }
}

=item C<setup_signals>

Complements the MooseX::Daemonize method by adding a handler for SIGHUP,
because the MooseX::Daemonize manpage lies about having a handler
"handle_sighup". It is commented in the code.

Re-opens the logfile on SIGHUP in daemon mode. In foreground mode, shut down
instead.

=cut

after setup_signals => sub {
    my $self = shift;
    $SIG{'HUP'} = sub {
        if ( $self->foreground ) {
            $self->shutdown();
        } else {
            Log::Log4perl->init( $self->_logging_configuration );
            $self->log( Log::Log4perl->get_logger() );
            $self->log->info('Re-opened Logfiles');
        }
    };
};

=item C<shutdown>

Log shoutdown.

=cut

before shutdown => sub {
    my $self = shift;
    Log::Log4perl->init( $self->_logging_configuration );
    $self->log( Log::Log4perl->get_logger() );
    $self->log->info('Daemon shutting down');
};

=item C<stop>

Log stop.

=cut

before stop => sub {
    my $self = shift;
    Log::Log4perl->init( $self->_logging_configuration );
    $self->log( Log::Log4perl->get_logger() );
    $self->log->info('Daemon shutting down');
};

=item C<restart>

Log restart.

=cut

after restart => sub {
    my $self = shift;
    Log::Log4perl->init( $self->_logging_configuration );
    $self->log( Log::Log4perl->get_logger() );
    $self->log->info('Daemon restarted');
};

=item C<start>

Starts the daemon functionality. Init Logging, read config, instantiate handler
objects, start AnyEvent Loop.

=cut

after start => sub {
    my $self = shift;

    return unless $self->is_daemon;
    $0 = 'anysyncd (manager process)';

    Log::Log4perl->init( $self->_logging_configuration );

    $self->log( Log::Log4perl->get_logger() );

    foreach my $section ( $self->config->Sections() ) {
        next if $section eq 'global';

        # build configuration for the handler
        my $config_for_handler = { name => $section };
        foreach my $sect_t ( 'global', $section ) {
            foreach my $key ( $self->config->Parameters($sect_t) ) {
                $config_for_handler->{$key} =
                    $self->config->val( $sect_t, $key );
            }
        }
        $config_for_handler->{filter} ||= '\.(swp|tmp)$';
        $self->log->debug(
            sprintf( 'Configuration for section "$section": %s',
                Dumper($config_for_handler) )
        );
        unless ($config_for_handler->{handler}
            and $config_for_handler->{watcher} )
        {
            $self->log->error( 'Configuration error: "'
                    . $section
                    . '" needs a "handler" and a "watcher"' );
            next;
        }

        # instantiate handler
        $self->{'handlers'}->{$section}->{'obj'} =
            $self->_load($config_for_handler) || next;

        $self->log->info( "Added "
                . $config_for_handler->{handler}
                . " as handler for $section" );
    }

    my $w = AnyEvent->condvar;  # stores whether a condition was flagged
    $w->recv;                   # enters "main loop" till $condvar gets ->send
};

# Loads handler packages
sub _load {
    my ( $self, $config ) = @_;

    eval "require $config->{handler}";

    if ($@) {
        $self->log->error(
                  "Could not load module $config->{handler} for section "
                . $config->{name}
                . ": $@" );
        return undef;
    }
    my $obj;
    eval { $obj = $config->{handler}->new( config => $config ); };
    if ($@) {
        $self->log->error(
            "Could not instantiate module $config->{handler} for section "
                . $config->{name}
                . ": $@" );
        return undef;
    }
    return $obj;
}

=back

=head1 LICENSE

This is released under the MIT License. See the B<COPYRIGHT> file.

=head1 AUTHOR

Alexander Wirt <alexander.wirt@credativ.de>,
Carsten Wolff <carsten.wolff@credativ.de>

=cut

__PACKAGE__->meta->make_immutable;

__END__

# vim: syntax=perl sw=4 ts=4 et shiftround

