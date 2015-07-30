package Anysyncd::Action::Rsync;

=head1 NAME

Anysyncd::Action::Rsync - Rsync based syncer for AnySyncd

=head1 SYNOPSIS

    [syncpair]

    handler = Anysyncd::Action::Rsync
    from = /tmp/testdir
    to = /tmp/testdir2
    watcher = /tmp/testdir

=head1 DESCRIPTION

Anysyncd::Action::Rsync is an rsync based syncer for anysyncd. It calls rsync
for every change event. If new events arrive before rsync has finished, it
tries up to three times to fully sync the whole tree without intermittent
events.

=head2 Configuration File

For a general description of the configuration file, look at the anysynd
documentation.

=head3 Rsync syncer options

=over

=item C<from> I<path>

This is the source path used in the rsync call.

=item C<to> I<path>

This is the destination path used in the rsync call.

=back

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
    my ( $self, $full_sync ) = @_;
    $self->_lock();
    $self->log->debug(
        "Processing files" . ( $full_sync ? " ($full_sync)" : "" ) );

    if ( !$full_sync and !scalar @{ $self->files() } ) {
        $self->log->debug("No files to sync");
        $self->_unlock();
        return;
    }

    my $rsync = File::Rsync->new(
        archive      => 1,
        compress     => 1,
        'rsync-path' => '/usr/bin/rsync'
    );

    # we try at least 3 times to empty the files list
    fork_call {
        my $errstr;
        foreach my $i ( 1 .. 3 ) {
            $self->log->debug("Rsync run $i");
            next if ( !$full_sync and !$self->files );
            $self->log->debug( "files: " . scalar( @{ $self->files } ) );
            if ( !$full_sync and !scalar( @{ $self->files } ) ) {
                $self->log->debug("No files left");
                last;
            }

            # we will give it another try, so clear error
            $errstr = "";

            # clear list of files
            $self->files_clear;

            $self->log->debug( "Syncing from: "
                    . $self->config->{'from'} . " - "
                    . $self->config->{'to'} );
            $rsync->exec(
                {   src  => $self->config->{'from'},
                    dest => $self->config->{'to'}
                }
            );
            if ( scalar( $rsync->err ) ) {
                $errstr = sprintf(
                    'Rsync from "%s" to "%s" failed: ',
                    $self->config->{'from'},
                    $self->config->{'to'},
                    join( "\n", $rsync->err )
                );
                $self->log->debug($errstr);
            }
            last if ( !$errstr and $full_sync );
        }
        croak($errstr) if $errstr;
    }
    sub {
        if ($@) {
            $self->_unlock();
            $self->_report_error($@);
            croak("There was an error in the fork call: $@");
        }
        $self->log->info("rsync calls done");
        $self->_stamp_file( "success", time() );
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
