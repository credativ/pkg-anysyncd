package Sync::Action::Rsync;

use Moose;
use File::Rsync;
use AnyEvent::Util;
use Carp qw(croak);

extends 'Sync::Action::Base';

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

# vim: syntax=perl sw=4 ts=4 et shiftround
