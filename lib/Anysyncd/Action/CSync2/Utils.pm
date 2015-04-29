package Anysyncd::Action::CSync2::Utils;

=head1 Anysyncd::Action::CSync2::Utils - Utility functions

These utility functions are shared by Anysyncd::Action::CSync2 and
anysyncd-csync2-remote-helper

=head2 Methods

=over 12

=cut

use Moose;

use File::Rsync;
use File::DirCompare;
use String::ShellQuote;

has 'name' => ( is => 'rw' );

=item C<rsync>

A wrapper around File::Rsync, that handles parameters, options and errors.
Most importantly, it checks if src and dest are really equal after the rsync
run and returns an error condition otherwise.

=cut

sub rsync {
    my ( $self, $proddir, $csyncdir ) = @_;
    $proddir =~ s/\/*$//;
    $csyncdir =~ s/\/*$//;

    my $rsync = File::Rsync->new(
        'verbose'    => 1,
        'archive'    => 1,
        'delete'     => 1,
        'checksum'   => 1,
        'rsync-path' => '/usr/bin/rsync'
    );

    my $err = !$rsync->exec(
        {   src  => shell_quote( $proddir . '/' ),
            dest => shell_quote($csyncdir)
        }
    );

    my $errstr = "";
    if ($err) {
        $errstr =
              "rsync(): rsync failed: "
            . join( ' ; ', $rsync->out ) . ' ; '
            . join( ' ; ', $rsync->err );
    } elsif ( !$self->_dirs_equal( $proddir, $csyncdir ) ) {
        $err    = 2;
        $errstr = "rsync(): rsync succeeded, but "
            . "directory equality did not check out.";
    }

    return ( $err, $errstr );
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

1;

=back

=head1 LICENSE

This is released under the MIT License. See the B<COPYRIGHT> file.

=head1 AUTHOR

Carsten Wolff <carsten.wolff@credativ.de>

=cut

# vim: syntax=perl sw=4 ts=4 et shiftround
