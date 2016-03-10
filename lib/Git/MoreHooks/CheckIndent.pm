## no critic (Documentation::PodSpelling)
## no critic (Documentation::RequirePodAtEnd)
## no critic (Documentation::RequirePodSections)
## no critic (ValuesAndExpressions::RequireInterpolationOfMetachars)
## no critic (Subroutines::RequireArgUnpacking)

package Git::MoreHooks::CheckIndent;

use strict;
use warnings;
use 5.010000;
use utf8;

# ABSTRACT: Check committed files for problems with indentation.

# VERSION: generated by DZP::OurPkgVersion

=head1 STATUS

Package Git::MoreHooks is currently being developed so changes in the existing hooks are possible.


=head1 SYNOPSIS

Use package via
L<Git::Hooks|Git::Hooks>
interface (git config file).

=for Pod::Coverage check_commit_at_client check_commit_at_server

=for Pod::Coverage check_ref


=head1 DESCRIPTION

This plugin allows user to enforce policies on the committed files.
It can define allowed indentation characters (space/tab/both),
tab width (1, 2, 3, 4, [..] characters) and on which files or file types
to apply which rules.


=head1 USAGE

To enable CheckIndent plugin, you need
to add it to the githooks.plugin configuration option:

    git config --add githooks.plugin CheckIndent

Git::Hooks::CheckIndent plugin hooks itself to the hooks below:

=over

=item * B<pre-commit>

This hook is invoked during the commit.

=item * B<update>

This hook is invoked multiple times in the remote repository during
C<git push>, once per branch being updated.

=item * B<pre-receive>

This hook is invoked once in the remote repository during C<git push>.

=item * B<ref-update>

This hook is invoked when a push request is received by Gerrit Code
Review.

=item * B<patchset-created>

This hook is invoked when a push request is received by Gerrit Code
Review for a virtual branch (refs/for/*).

=item * B<draft-published>

The draft-published hook is executed when the user publishes a draft change,
making it visible to other users.

=back


=head1 CONFIGURATION

This plugin is configured by the following git options.

=head3 githooks.checkindent.file REGEXP PARAMETERS

A regular expressions matches against the file name.
If config has several B<file> items they are used in their
order of appearance until a match is found. When a match is found,
the parameters are applied to check the file.

Parameters are I<indent-char> (allowed values: C<space>, C<tab>, C<both>) and
I<indent-size> (allowed content: an integer number).

    file = ^proj1/old/.* indent-char:both indent-size:2
    file = \.(c|h|cpp|hpp)$ indent-char:tab
    file = \.py$ indent-char:space indent-size:4

N.B. The file name is a regular expression which will be matched against
the whole path of the file. The file name is not
a L<File::Glob|File::Glob> pattern (like Git::Hooks::CheckFile uses).


=head1 EXPORTS

This module exports the following routines that can be used directly
without using all of Git::Hooks infrastructure.

=head2 check_commit_at_client GIT

This is the routine used to implement the C<pre-commit> hook. It needs
a C<Git::More> object.

=head2 check_commit_at_server GIT, COMMIT

This is the routine used to implement the C<pre-commit> hook. It needs
a C<Git::More> object and a commit hash from C<Git::More::get_commit()>.

=head2 check_affected_refs GIT

This is the routing used to implement the C<update> and the
C<pre-receive> hooks. It needs a C<Git::More> object.

=head2 check_patchset GIT, HASH

This is the routine used to implement the C<patchset-created> Gerrit
hook. It needs a C<Git::More> object and the hash containing the
arguments passed to the hook by Gerrit.


=head1 NOTES

Thanks go to Gustavo Leite de Mendonça Chaves for his
L<Git::Hooks|https://metacpan.org/pod/Git::Hooks> package.

=cut

use Git::MoreHooks::CheckCommitBase \&do_hook;

use Git::Hooks qw{:DEFAULT :utils};
use Path::Tiny;
use Log::Any qw{$log};
use Params::Validate qw(:all);


my $PKG = __PACKAGE__;
my ($CFG) = __PACKAGE__ =~ /::([^:]+)$/msx;
$CFG = 'githooks.' . $CFG;

=head1 SUBROUTINES/METHODS

=for Pod::Coverage check_for_indent do_hook handle_file

=cut

####################
# Hook configuration, check it and set defaults.

sub _setup_config {
    my ($git) = @_;

    my $config = $git->get_config();
    $log->debugf( '_setup_config(): Current Git config:\n%s.', $config );

    # Put empty hash if there is no config items.
    $config->{ lc $CFG } //= {};

    # Set default config values.
    my $default = $config->{ lc $CFG };
    $default->{'file'} //= [];
    $default->{'exception'} //= [];

    # Check validity of config items.
    foreach my $file_def ( @{$default->{'file'}} ) {
        $log->debugf( '_setup_config(): Check for validity, config item: \'%s\'.', $file_def );
        if (
            ## no critic (RegularExpressions::ProhibitComplexRegexes)
            $file_def !~ m{^
            (?:[[:graph:]]+)
            (?:
                (?:[[:space:]]{1,}indent-size:[[:digit:]]+){1,}
                | (?:[[:space:]]{1,}indent-char:(?:space|tab|both))
            ){1,}
            (?:[[:space:]]{0,})
            $}msx
            ## use critic (RegularExpressions::ProhibitComplexRegexes)
          )
        {
            $git->error( $PKG, 'Faulty config item: \'' . $file_def . '\'.' );
            return 0;
        }
    }
    foreach my $exc_def ( @{$default->{'exception'}} ) {
        $log->debugf( '_setup_config(): Check for validity, config item: \'%s\'.', $exc_def );
        if (
            ## no critic (RegularExpressions::ProhibitComplexRegexes)
            $exc_def !~ m{^
            (?:[[:space:]]{0,})   (?# Free spacing before)
            (?:[[:graph:]]+)      (?# File name pattern)
            (?:[[:space:]]{1,})   (?# Required spacing)
            (?:[[:graph:]]+)      (?# Regular expression)
            (?:[[:space:]]{0,})   (?# Free spacing after)
            $}msx
            ## use critic (RegularExpressions::ProhibitComplexRegexes)
          )
        {
            $git->error( $PKG, 'Faulty config item: \'' . $exc_def . '\'.' );
            return 0;
        }
    }
    return 1;
}

####################
# Internal functions

sub check_for_indent {
    my %params = validate(
        @_,
        {
            file_as_string => { type => SCALAR, },
            indent_char    => {
                type    => SCALAR,
                default => q{ },
                regex   => qr/[[:space:]]{1,}/msx,
            },
            indent_size => {
                type    => SCALAR,
                default => 4,
                regex   => qr/[[:digit:]]{1,}/msx,
            },
            exceptions => {
                type    => ARRAYREF,
                default => [],
            },
        },
    );
    my $ic     = $params{'indent_char'};
    my $row_nr = 1;
    my %errors;
    foreach my $row ( split qr/\n/msx, $params{'file_as_string'} ) {

        # Check for faulty tab chars (space/tab)
        my ($indents) = $row =~ m/^([[:space:]]{0,})/msx;
        if ( length $indents > 0 &&
            (
                $indents !~ m/^[$ic]{1,}$/msx
                || (($ic ne qq{\t}) && (length $indents) % $params{'indent_size'} != 0)
            ) ) {
            # If there is an exception regexp that matches this row,
            # then skip logging it as error.
            if (!map { $row =~ m/$_/msx } @{$params{'exceptions'}}) {
                $errors{$row_nr} = $row;
            } else {
                $log->debugf('Except this row: \'%s\'', $row);
            }
        }
        $row_nr++;
    }
    return %errors;
}

####################
# Callback function

sub do_hook {
    my ($git, $hook_name, $opts) = @_;
    $log->tracef( 'do_hook(%s)', (join q{:}, @_) );

    return 1 if im_admin($git);
    if ( !_setup_config($git) ) {
        return 0;
    }

    my $errors = 0;
    if ( $hook_name eq 'pre-commit' ) {
        my @files = $git->filter_files_in_index('AM');
        foreach my $file (@files) {
            my $read_file_func_ptr = sub { return path(shift)->slurp( { 'binmode' => ':raw' } ) };
            $errors += handle_file($git, $file, $read_file_func_ptr, ':0');
        }
    } elsif ( $hook_name eq 'patchset-created' || $hook_name eq 'draft-published' ) {
        my @files = $git->filter_files_in_commit('AM', $opts->{'gerrit-opts'}->{'--commit'});
        foreach my $file (@files) {
            my $read_file_func_ptr = sub {
                my ($file, $commit) = @_;
                my $tmpfile_name = $git->blob($commit, $file);
                return path($tmpfile_name)->slurp( { 'binmode' => ':raw' } );
            };
            $errors += handle_file($git, $file, $read_file_func_ptr, $opts->{'gerrit-opts'}->{'--commit'});
        }
    } elsif ( $hook_name eq 'update' || $hook_name eq 'pre-receive' || $hook_name eq 'ref-update' ) {
        foreach my $ref ($git->get_affected_refs()) {
            my ($old_commit, $new_commit) = $git->get_affected_ref_range($ref);
            my @files = $git->filter_files_in_range('AM', $old_commit, $new_commit);
            foreach my $file (@files) {
                my $read_file_func_ptr = sub {
                    my ($file, $commit) = @_;
                    my $tmpfile_name = $git->blob($commit, $file);
                    return path($tmpfile_name)->slurp( { 'binmode' => ':raw' } );
                };
                $errors += handle_file($git, $file, $read_file_func_ptr, $new_commit);
            }
        }
    }
    return $errors == 0;
}
sub handle_file {
    my ($git, $filename, $read_file_func_ptr, $commit) = @_;
    $log->tracef( 'handle_file(%s)', (join q{:}, @_) );
    my @file_defs = $git->get_config($CFG => 'file');
    my %opts;
    my $errors = 0;
    foreach my $file_def (@file_defs) {
        my ($file_regexp, $options) = split q{ }, $file_def, 2;
        if ( $filename =~ m/$file_regexp/msx ) {
            ($opts{'indent_size'}) = $options =~ m/indent-size:([[:digit:]]+)/msx;
            ($opts{'indent_char'}) = $options =~ m/indent-char:(space|tab|both)/msx;
            my $file_as_string = &{$read_file_func_ptr}($filename, $commit);
            my %exceptions;
            foreach my $exc_row ($git->get_config($CFG => 'exception')) {
                my ($exc_file_regexp, $exc) = split qr{[[:space:]]+}msx, $exc_row;
                if ($filename =~ m/$exc_file_regexp/msx) {
                    $exceptions{$exc_file_regexp} = $exc;
                }
            }
            my %results = check_for_indent(
                'file_as_string' => $file_as_string,
                'indent_char'    => $opts{'indent_char'} eq 'space' ? q{ } : qq{\t},
                'indent_size'    => $opts{'indent_size'},
                'exceptions'     => [values %exceptions],
            );
            foreach my $row_nr (keys %results) {
                $git->error( $PKG, "Indent error ($commit, $filename:$row_nr): '$results{$row_nr}'" );
                $errors++;
            }
            last;
        }
    }
    return $errors;
}

1;

