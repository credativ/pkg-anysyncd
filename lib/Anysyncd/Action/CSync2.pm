package Anysyncd::Action::CSync2;

use Moose;
use File::Rsync;
use Net::OpenSSH;
use AnyEvent::Util;
use File::Basename qw(basename dirname);
use File::Spec;
use File::DirCompare;
use Carp qw(croak);

extends 'Anysyncd::Action::Base';

has _retry_interval => (
    is            => 'rw',
    isa           => 'Int',
    builder       => '_build_retry_interval',
    lazy          => 1,
    documentation => " when local sync fails, retry in this interval"
);

sub _build_retry_interval {
    my $self = shift;
    return $self->config->{'retry_interval'} || 2;
}

sub BUILD {
    my $self = shift;

    # do some sanity checks
    if (   !$self->config->{'prod_dir'}
        or !$self->config->{'csync_dir'}
        or !$self->config->{'remote_hosts'} )
    {
        croak(    "BUILD(): At least one of 'prod_dir', 'csync_dir' and "
                . "'remote_hosts' is not configured." );
    }

    # Do one full sync at startup
    unless ( $self->_noop() ) {
        $self->log->info("BUILD(): executing startup sync");
        $self->process_files('full');
    }
}

sub process_files {
    my ( $self, $full_sync ) = @_;
    $self->_lock();
    $self->log->debug("process_files(): Processing files");

    if ( !$full_sync and !scalar @{ $self->files() } ) {
        $self->log->debug("process_files(): No files to sync");
        $self->_unlock();
        return;
    }

    fork_call {
        my ( $err, $errstr, $start_ts ) = ( 0, "", undef );

      # we try very hard to finish one local sync with no intermittent changes
        foreach my $i ( 1 .. 100 ) {
            $self->log->debug( "process_files(): local rsync run $i files: "
                    . scalar( @{ $self->files } ) );

            # clear list of files
            $self->files_clear;

            $start_ts = time();
            $err      = $self->_local_rsync();

            $self->log->debug( "process_files(): local rsync finished "
                    . "within "
                    . ( time() - $start_ts )
                    . " seconds" );

            if ( $err or scalar( @{ $self->files } ) ) {
                $self->log->debug( "process_files(): rsync was unsuccessfull "
                        . "or new file changes arrived." );

                my $diff_ts = time() - $start_ts;
                while ( $diff_ts < $self->_retry_interval ) {
                    my $sleep = $self->_retry_interval - $diff_ts;
                    $self->log->debug(
                              "process_files(): delaying next run by "
                            . "${sleep}s" );
                    sleep($sleep);
                    $diff_ts = time() - $start_ts;
                }
            } else {
                $self->log->debug( "process_files(): No more file changes "
                        . "left to sync" );
                ( $err, $errstr ) = ( 0, "" );
                last;
            }
        }
        if ($err) {
            $errstr = "process_files(): could not achieve a consistent local "
                . "sync state after 100 retries.";
        }

        # now follows everything involving the network
        ( $err, $errstr ) = $self->_check_stamps()  if ( !$err );
        ( $err, $errstr ) = $self->_csync2()        if ( !$err );
        ( $err, $errstr ) = $self->_commit_remote() if ( !$err );

        return ( $err, $errstr, $start_ts );
    }
    sub {
        my ( $err, $errstr, $start_ts ) = @_;
        if ($@) {
            $err    = 1;
            $errstr = "process_files(): My child died: $@";
        }
        if ($err) {
            $self->_report_error($errstr);
        } else {
            $self->_stamp_file( "success", $start_ts );
            $self->log->info("process_files(): Synchronization succeeded.");
        }
        $self->_unlock();
    };
}

sub _commit_remote {
    my ($self) = @_;
    my $proddir = $self->config->{'prod_dir'};
    my ( $basedir, $name ) = ( dirname($proddir), basename($proddir) );
    my $proddir_tmp = File::Spec->join( $basedir, ".$name.tmp" );
    my $csyncdir = $self->config->{'csync_dir'};
    $proddir =~ s/\/*$//;
    $csyncdir =~ s/\/*$//;
    my $errstr = "";
    my $err    = 0;

    $self->log->debug("_commit_remote(): sub got called");

    for my $host ( split( '\s+', $self->config->{'remote_hosts'} ) ) {
        my $ssh = Net::OpenSSH->new($host);

        my $ok = $ssh->test("rsync -caHAXq --delete $csyncdir/ $proddir_tmp");

        if ($ok) {
            $ok = $ssh->test("diff -qrN $csyncdir $proddir_tmp");
        }

        if ($ok) {
            $ok = $ssh->test( "
                if [ -d $proddir ]; then
                    mv $proddir $proddir.bak;
                fi;
                mv $proddir_tmp $proddir;
                if [ -d $proddir.bak ]; then
                    mv $proddir.bak $proddir_tmp;
                fi;"
            );
        }

        if ($ok) {
            $self->log->debug("_commit_remote(): committing $host succeeded");
        } else {
            $err++;
            $errstr .= "_commit_remote(): committing $host failed: "
                . $ssh->error . "\n\n";
        }
    }
    return ( $err, $errstr );
}

sub _csync2 {
    my ($self) = @_;
    my ( $err, $errstr ) = ( 0, "" );

    $self->log->debug("_csync2(): sub got called");

    my $csync_out = `csync2 -x 2>&1`;
    $err = $?;
    if ($err) {
        $errstr = "_csync2(): csync2 failed with $err: $csync_out";
    }
    return ( $err, $errstr );
}

sub _local_rsync {
    my ($self)   = @_;
    my $proddir  = $self->config->{'prod_dir'};
    my $csyncdir = $self->config->{'csync_dir'};
    $proddir =~ s/\/*$//;
    $csyncdir =~ s/\/*$//;

    $self->log->debug("_local_rsync(): sub got called");

    my $rsync = File::Rsync->new(
        'verbose'    => 1,
        'archive'    => 1,
        'delete'     => 1,
        'checksum'   => 1,
        'rsync-path' => '/usr/bin/rsync'
    );

    my $err = !$rsync->exec(
        {   src  => $proddir . '/',
            dest => $csyncdir
        }
    );

    if ($err) {
        $self->log->error( "_local_rsync(): Local rsync failed: "
                . join( ' ; ', $rsync->out ) . ' ; '
                . join( ' ; ', $rsync->err ) );
    } elsif ( !$self->_dirs_equal( $proddir, $csyncdir ) ) {
        $err = 2;
        $self->log->error( "_local_rsync(): Local rsync succeeded, but "
                . "directory equality did not check out." );
    }

    return $err;
}

sub _dirs_equal {
    my ( $self, $dir1, $dir2 ) = @_;

    sleep 1;

    my $equal = 1;
    if ( not -d $dir2 ) {
        $equal = 0;
    } else {
        File::DirCompare->compare(
            $dir1, $dir2,
            sub {
                $equal = 0;    # every call of the sub indicates a change
            }
        );
    }

    return $equal;
}

sub _check_stamps {
    my ($self) = @_;
    my $errstr = "";
    my $err    = 0;

    $self->log->debug("_check_stamps(): sub got called");

    for my $host ( split( '\s+', $self->config->{'remote_hosts'} ) ) {
        my $ssh = Net::OpenSSH->new($host);

        my $fn =
            "/var/lib/anysyncd/" . $self->config->{name} . "_success_stamp";
        my $succ = $ssh->capture("[ -f $fn ] && cat $fn; exit 0;");
        $succ =~ s/[^0-9]//g;

        unless ( $ssh->error ) {
            $fn =
                  "/var/lib/anysyncd/"
                . $self->config->{name}
                . "_lastchange_stamp";
            my $lastchange = $ssh->capture("[ -f $fn ] && cat $fn; exit 0");
            $lastchange =~ s/[^0-9]//g;

            if (   !$ssh->error
                and $succ
                and $lastchange
                and ( $lastchange > $succ ) )
            {
                $err++;
                $errstr .= "_check_stamps(): remote host $host seems to have "
                    . "unsynced changes. Syncing our changes to that host might be unsafe.\n\n";
            }
        }

        if ( $ssh->error ) {
            $err++;
            $errstr
                .= "_check_stamps(): getting timestamps from $host failed: "
                . $ssh->error . "\n\n";
        }

        if ( !$err ) {
            $self->log->debug("_check_stamps(): stamps on $host check out");
        }
    }
    return ( $err, $errstr );
}

1;

=pod

=head1 LICENSE

This is released under the MIT License. See the B<COPYRIGHT> file.

=head1 AUTHOR

Carsten Wolff <carsten.wolff@credativ.de>

=cut

# vim: syntax=perl sw=4 ts=4 et shiftround
