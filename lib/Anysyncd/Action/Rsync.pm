package Anysyncd::Action::Rsync;

=pod
=head1 NAME

Anysyncd::Action::Rsync - Rsync based syncer for AnySyncd

=head1 SYNOPSIS

[syncpair]

handler = Anysyncd::Action::Rsync
from = /tmp/testdir
to = /tmp/testdir2
watcher = /tmp/testdir

=head1 DESCRIPTION

Anysyncd::Action::Rsync is an rsync based syncer for AnySyncd, it calls rsync
for every change event. If there are any later events after the first sync, it tries
up to three time to sync the whole tree, until there are any new events.

It doesn't accept any Syncer specific options.

=cut

use Moose;
use File::Rsync;
use AnyEvent::Util;
use Carp qw(croak);

extends 'Anysyncd::Action::Base';

sub BUILD {
    my $self = shift;

    # do some sanity checks
    if ( !$self->config->{'to'} ) {
        croak 'to parameter is missing in configuration';
    }
    if ( !$self->config->{'from'} ) {
        croak 'from parameter is missing in configuration';
    }
}

sub process_files {
    my $self = shift;
    $self->_timer(undef);
    $self->log->debug("Processing files");

    if ( !scalar @{ $self->files() } ) {
        $self->log->debug("No files to sync");
        return;
    }

    $self->_lock();

    my $rsync = File::Rsync->new(
        archive      => 1,
        compress     => 1,
        'rsync-path' => '/usr/bin/rsync'
    );

    # we try at least 3 times to empty the files list
    fork_call {
        foreach my $i ( 1 .. 3 ) {
            $self->log->debug("Rsync run $i");
            next unless $self->files;
            $self->log->debug( "files: " . scalar( @{ $self->files } ) );
            if ( !scalar( @{ $self->files } ) ) {
                $self->log->debug("No files left");
                last;
            }

            # clear list of files
            $self->files_clear;

            $rsync->exec(
                {   src  => $self->config->{'from'},
                    dest => $self->config->{'to'}
                }
            ) or $self->log->error("Failed");
            $self->log->debug( "Syncing from: "
                    . $self->config->{'from'} . " - "
                    . $self->config->{'to'} );
            if ( scalar( $rsync->err ) ) {
                $self->log->debug(
                    sprintf(
                        'Rsync from "%s" to "%s" failed: ',
                        $self->config->{'from'}, $self->config->{'to'},
                        join( "\n", $rsync->err )
                    )
                );
            }
        }
    }
    sub {
        if ($@) {
            croak("There was an error in the fork call: $@");
        }
        $self->log->info("rsync calls done");
        $self->_unlock();
    };
}

1;

=pod

=head1 LICENSE

This is released under the MIT License. See the B<COPYRIGHT> file.

=head1 AUTHOR

Alexander Wirt <alexander.wirt@credativ.de>

=cut

# vim: syntax=perl sw=4 ts=4 et shiftround
