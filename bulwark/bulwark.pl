#!/usr/bin/env perl
use strict;
use warnings;

our $VERSION = '0.1';

use Data::Dumper;
use Getopt::Long;

GetOptions
	'config=s' => \my $config_file,
	'dry-run' => \my $dry_run,
	'verbose' => \my $verbose
	or die usage();

die usage() unless defined $config_file;

my $config = read_config($config_file);

sub usage {
	<<EOS;
$0 --config FILE [--dry-run] [--verbose]
v$VERSION
EOS
}

exit 0;

use constant IDENTIFIER_RE => qr/\A[A-Za-z_][A-Za-z0-9_-]*\z/;

sub read_config {
	my $config_file = shift;
	if (defined(my $config = do $config_file)) {
		return check_config($config);
	}
	die "$0: can not read file $config_file: $!\n" if $!;
	die "$0: can not parse file $config_file:\n $@\n" if $@;
}

sub check_config {
	my $config = shift;

	die "$0: config must return a HASH ref!" unless ref $config eq 'HASH';

	check_keys('toplevel', $config, [qw/SETTINGS DEFAULTS TO BACKUPS/]);

	check_keys('settings', $config->{SETTINGS}, [qw/MACHINE_NAME MAILTO/]);
	check_reftype('settings.machine_name', $config->{SETTINGS}{MACHINE_NAME}, '');
	check_reftype('settings.mailto', $config->{SETTINGS}{MAILTO}, 'ARRAY');

	check_keys('defaults', $config->{DEFAULTS}, [], [qw/DB DIR GPG/]);

	if ($config->{DEFAULTS}{DB}) {
		check_keys('defaults.db', $config->{DEFAULTS}{DB}, [], [qw/USER PASS/]);
		check_reftype('defaults.db.user', $config->{DEFAULTS}{DB}{USER}, '') if $config->{DEFAULTS}{DB}{USER};
		check_reftype('defaults.db.pass', $config->{DEFAULTS}{DB}{PASS}, '') if $config->{DEFAULTS}{DB}{PASS};
	}

	if ($config->{DEFAULTS}{DIR}) {
		check_keys('defaults.dir', $config->{DEFAULTS}{DIR}, [], [qw/EXCLUDE/]);
		check_reftype('defaults.dir.exclude', $config->{DEFAULTS}{DIR}{EXCLUDE}, 'ARRAY') if $config->{DEFAULTS}{DIR}{EXCLUDE};
	}

	if ($config->{DEFAULTS}{GPG}) {
		check_keys('defaults.gpg', $config->{DEFAULTS}{GPG}, [], [qw/MODE PASS/]);
		check_reftype('defaults.gpg.mode', $config->{DEFAULTS}{GPG}{MODE}, '') if $config->{DEFAULTS}{GPG}{MODE};
		check_reftype('defaults.gpg.pass', $config->{DEFAULTS}{GPG}{PASS}, '') if $config->{DEFAULTS}{GPG}{PASS};
	}

	for my $k (keys %{ $config->{TO} }) {
		check_re("to.$k", $k, IDENTIFIER_RE);
		my $dest_def = $config->{TO}{$k};
		if ($dest_def->{DIR}) {
			check_keys("to.$k", $dest_def, [qw/DIR/], [qw/KEEP/]);
			check_reftype("to.$k.DIR", $dest_def->{DIR}, '');
			check_reftype("to.$k.KEEP", $dest_def->{KEEP}, '') if $dest_def->{KEEP};
		}
		elsif ($dest_def->{BUCKET}) {
			check_keys("to.$k", $dest_def, [qw/BUCKET/], [qw/KEEP CFG MODE PASS/]);
			check_reftype("to.$k.BUCKET", $dest_def->{BUCKET}, '');
			for my $key (qw/KEEP CFG MODE PASS/) {
				check_reftype("to.$k.$key", $dest_def->{$key}, '') if $dest_def->{$key};
			}
		}
		else {
			die "$0: unknown type of TO definition $k, contains neither DIR nor BUCKET\n";
		}
	}

	for my $k (keys %{ $config->{BUCKET} }) {
		check_re("backups.$k", $k, IDENTIFIER_RE);
		my $backup_def = $config->{BUCKET}{$k};
		check_keys("backups.$k", $backup_def, [qw/FROM TO/]);

		check_reftype("backups.$k.FROM", $backup_def->{FROM}, 'HASH');
		for my $from_k (keys %{ $backup_def->{FROM} }) {
			check_re("backups.$k.FROM.$from_k", $backup_def->{FROM}{$from_k}, IDENTIFIER_RE);
		}


		check_reftype("backups.$k.TO", $backup_def->{TO}, 'ARRAY');
	}

	# XXX -- more checking in general but i also forgot the check_reftype of the sections in general. they have to be hashes.

	return $config;
}

sub check_keys {
	my ($section, $hash, $required_keys, $optional_keys) = @_;
	$optional_keys ||= [];

	my %existing_keys = map +($_ => 1), keys %$hash;

	for my $k (@$required_keys) {
		die "$0: missing key in config in $section: $k\n" unless exists $hash->{$k};
	}

	delete @existing_keys{ @$required_keys, @$optional_keys };
	die "$0: extra key(s) in config in $section: @{[ keys %existing_keys ]}\n" if keys %existing_keys;
}

sub check_reftype {
	my ($section, $value, $want_ref_type) = @_;
	my $got_ref_type = ref $value;
	my $want_ref_type_label = $want_ref_type || 'SCALAR';
	die "$0: bad value in config in $section, expected $want_ref_type_label, got @{[$got_ref_type || $value]}\n" if $got_ref_type ne $want_ref_type;
}

sub check_re {
	my ($section, $value, $re) = @_;
	die "$0: bad value in config in $section, expected $re, got $value\n" unless $value =~ $re;
}

