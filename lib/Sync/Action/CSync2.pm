package Sync::Action::CSync2;

use Moose;
use AnyEvent::Util;
use Carp qw(croak);

extends 'Sync::Action::Base';

sub BUILD {
    my $self = shift;

    # do some sanity checks
#    if ( !$self->config->{'to'} ) {
#        croak 'to parameter is missing in configuration';
#    }
#    if ( !$self->config->{'from'} ) {
#        croak 'from parameter is missing in configuration';
#    }

    # Do one sync at startup
    $self->log->info(__PACKAGE__ . " BUILD(): startup sync");
    $self->process_files(1);
}

sub process_files {
    my ($self, $full_sync) = @_;
    $self->_timer(undef);
    $self->log->debug(__PACKAGE__ . " process_files(): Processing files");

    if ( !$full_sync and !scalar @{ $self->files() } ) {
        $self->log->debug(__PACKAGE__ . " No files to sync");
        return;
    }

    $self->_lock();

    # we try at least 5 times to empty the files list
    fork_call {
        foreach my $i ( 1 .. 100 ) {
            $self->log->debug(__PACKAGE__ . " csync2 run $i");
            next unless ($self->files or $full_sync);
            $self->log->debug( "files: " . scalar( @{ $self->files } ) );
            if ( !scalar( @{ $self->files } ) and !$full_sync ) {
                $self->log->debug(__PACKAGE__ . " No more file changes left to sync");
                last;
            }

            # clear list of files
            $self->files_clear;
            $full_sync = 0;

            my $start_ts = time();
            my @csync_out = `csync2 -x 2>&1`;
            my $csync_ret = $?;
            $self->log->debug( __PACKAGE__ . " csync2 finished with exit code " .
                "$csync_ret within " . (time() - $start_ts) . " seconds");

            my $diff_ts = time() - $start_ts;
            while ($diff_ts < 5) {
                $self->log->debug( __PACKAGE__ . " delaying next run by " .
                    ( 5 - $diff_ts ) . "s" );
                sleep ( 5 - $diff_ts );
                $diff_ts = time() - $start_ts;
            }
        }
    }
    sub {
        if ($@) {
            croak(__PACKAGE__ . " There was an error in the fork call: $@");
        }
        $self->log->info(__PACKAGE__ . " csync2 calls done");
        $self->_unlock();
    };
}

1;

# vim: syntax=perl sw=4 ts=4 et shiftround
