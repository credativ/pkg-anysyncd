package Anysyncd::Action::Base;

=head1 NAME

Anysyncd::Action::Base - Common interface for all sync actions

=head1 SYNOPSIS

    use Anysyncd::Action::Base;
    my $action = Anysyncd::Action::Base->new( config => $config );

=head1 DESCRIPTION

The base module for all syncer actions for anysyncd. It takes care of handling
watcher events and defines the interface for all action implementations, which
is very simple, all actions should look similar to this:

    use Moose;
    extends 'Anysyncd::Action::Base';

    sub process_files {
        $self->_lock();
        fork_call {
            for ( @{ $self->files() } ) {
                ... do the actual sync
            }
            $self->files_clear;
        }
        sub {
            $self->_stamp_file( "success", time() ) unless ($@);
        };
        $self->_unlock();
    }

=head2 Methods

This class has no public methods.

=cut

use Moose;
use MooseX::AttributeHelpers;

use Carp qw (croak);
use AnyEvent::Util;
use AnyEvent::DateTime::Cron;
use AnyEvent::Filesys::Notify;
use IPC::ShareLite;
use Storable qw( freeze thaw );
use Email::MIME;
use Email::Sender::Simple;
use Try::Tiny;

has 'log' => ( is => 'rw' );
has 'config' => ( is => 'rw', isa => 'HashRef', required => 1 );
has '_timer' => ( is => 'rw', predicate => '_has_timer' );
has '_watcher' => ( is => 'rw' );
has '_is_locked' => (
    traits  => ['Bool'],
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    handles => {
        _lock        => 'set',
        _unlock      => 'unset',
        _is_unlocked => 'not',
    },
);
has _files => ( is => 'rw' );
has _stamps => ( is => 'rw', isa => 'HashRef', default => sub { {} } );

sub BUILD {
    my $self = shift;

    $self->log(
        Log::Log4perl->get_logger(
            $self->config->{handler} . '::' . $self->config->{name}
        )
    );
    my $share = IPC::ShareLite->new(
        -key     => int( rand(4) ),
        -create  => 'yes',
        -destroy => 'yes'
    ) or die $!;

    $self->_files($share);
    $self->_files->store( freeze( [] ) );

    $self->_create_watcher();

    if ( $self->config->{'cron'} ) {
        AnyEvent::DateTime::Cron->new()->add(
            $self->config->{'cron'} => sub {
                $self->_create_watcher();
                $self->process_files('full')
                    if (!$self->_noop
                    and !$self->_timer
                    and $self->_is_unlocked );
            }
        )->start;
    }
}

sub _create_watcher {
    my $self = shift;
    if ( $self->_noop() ) {
        if ( $self->_watcher() ) {
            $self->_watcher(undef);
            $self->log->info(
                "Watcher removed for " . $self->config->{name} );
        }
    } elsif ( not $self->_watcher ) {
        $self->_watcher(
            AnyEvent::Filesys::Notify->new(
                dirs         => [ $self->config->{watcher} ],
                filter       => sub { shift !~ /$self->config->{filter}/ },
                parse_events => 1,
                cb           => sub {
                    foreach my $event (@_) {
                        $self->add_files( $event->path );
                    }
                }
            )
        );
        if ( $self->_watcher ) {
            $self->log->info( "Watcher added for " . $self->config->{name} );
        }
    }
}

sub _noop {
    my $self = shift;
    return ( $self->config->{'noop_file'}
            and not -e $self->config->{'noop_file'} );
}

#
# FIXME: The next 3 functions are not sufficient for syncer implementations
# that want to synchronise only files gotten from events. For this to work,
# there needs at least be a function to atomically "pop" files from the list
# and the "files" method needs to be made atomic, too
#
sub files {
    my $self = shift;
    if (@_) {
        my @files;
        if ( $self->_files->fetch ) {
            push @files, thaw( $self->_files->fetch );
            push @files, @_;
        } else {
            @files = (@_);
        }
        $self->_files->store( freeze( \@files ) );
    } else {
        return $self->_files->fetch ? thaw( $self->_files->fetch ) : [];
    }
}

sub add_files {
    my $self      = shift;
    my @new_files = (@_);

    # check for noop state
    $self->_create_watcher();
    return unless $self->_watcher;

    $self->files(@new_files);
    $self->log->debug(
        "Added " . join( " ", @new_files ) . " to files queue" );

    # always wait a few seconds for more events to come in
    if ( !$self->_timer ) {
        my $w = AnyEvent->timer(
            after => $self->config->{'waiting_time'} || 5,
            cb => sub {
                $self->_timer(undef);
                $self->process_files if $self->_is_unlocked;
            }
        );
        $self->_timer($w);
        $self->_stamp_file( "lastchange", time() );
    }
}

sub files_clear {
    my $self = shift;
    $self->_files->store( freeze( [] ) );
}

sub _report_error {
    my ( $self, $errstr ) = @_;

    # log
    $self->log->error($errstr);

    # e-mail
    return
        unless ( $self->config->{'admin_from'}
        and $self->config->{'admin_to'} );

    my $message = Email::MIME->create(
        header_str => [
            From    => $self->config->{'admin_from'},
            To      => $self->config->{'admin_to'},
            Subject => "anysyncd failed to sync " . $self->config->{name},
        ],
        attributes => {
            encoding => 'quoted-printable',
            charset  => 'UTF-8',
        },
        body_str => "The following error occured:\n\n$errstr",
    );

    # send the message
    try {
        Email::Sender::Simple->send($message);
    }
    catch {
        $self->log->error("Failed to send mail: $_");
    };
}

sub _stamp_file {
    my ( $self, $type, $stamp ) = @_;
    my $ret = $self->_stamps->{$type};
    my $fn =
        "/var/lib/anysyncd/" . $self->config->{name} . "_" . $type . "_stamp";
    if ($stamp) {
        open( my $fh, ">", $fn )
            or $self->_report_error("Failed to open $fn: $!");
        print $fh $stamp;
        close $fh;
        $ret = $stamp;
    } elsif ( !$ret and -e $fn ) {

        # read from disk if there's no mem state, yet
        open( my $fh, "<", $fn )
            or $self->_report_error("Failed to open $fn: $!");
        $ret = do { local $/ = <$fh> };
        close $fh;
    }
    $self->_stamps->{$type} = $ret;
    return $ret;
}

1;

=head1 LICENSE

This is released under the MIT License. See the B<COPYRIGHT> file.

=head1 AUTHOR

Alexander Wirt <alexander.wirt@credativ.de>,
Carsten Wolff <carsten.wolff@credativ.de>

=cut

# vim: syntax=perl sw=4 ts=4 et shiftround
