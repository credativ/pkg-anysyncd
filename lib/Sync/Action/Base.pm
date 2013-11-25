package Sync::Action::Base;

use Moose;
use MooseX::AttributeHelpers;

use Carp qw (croak);
use AnyEvent::Util;
use AnyEvent::DateTime::Cron;
use IPC::ShareLite;
use Storable qw( freeze thaw );

has 'log' => ( is => 'rw' );
has 'config' => ( is => 'rw', isa => 'HashRef', required => 1 );
has '_timer' => ( is => 'rw', predicate => '_has_timer', );
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

#
sub BUILD {
    my $self = shift;

    $self->log(
        Log::Log4perl->get_logger( $self->config->{handler} .  '::' . $self->config->{name} )
    );
    my $share = IPC::ShareLite->new(
        -key     => int( rand(4) ),
        -create  => 'yes',
        -destroy => 'yes'
    ) or die $!;

    $self->_files($share);
    $self->_files->store( freeze( [] ) );

    if ( $self->config->{'cron'} ) {
        AnyEvent::DateTime::Cron->new()
            ->add( $self->config->{'cron'} => sub {
                $self->process_files if ( !$self->_timer and $self->_is_unlocked );
            } )
            ->start;
    }
}

sub files_clear {
    my $self = shift;
    $self->_files->store( freeze( [] ) );
}

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

    $self->files(@new_files);
    $self->log->info( "Added " . join( " ", @new_files ) );

    if ( !$self->_timer && $self->_is_unlocked ) {
        my $waiting_time = $self->config->{'waiting_time'} || 5;
        my $w = AnyEvent->timer(
            after => $waiting_time,
            cb    => sub { $self->process_files }
        );
        $self->_timer($w);
    }

}

1;

# vim: syntax=perl sw=4 ts=4 et shiftround
