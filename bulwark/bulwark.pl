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
		return check_config_dvxsd($config);
	}
	die "$0: can not read file $config_file: $!\n" if $!;
	die "$0: can not parse file $config_file:\n $@\n" if $@;
}

sub check_config_dvxsd {
	my $config = shift;
	use Config::Validate qw/mkpath/;
	my $def = {
		SETTINGS => {
			type => 'nested',
			child => {
				MACHINE_NAME => {
					type => 'string',
				},
				MAILTO => {
					type => 'array',
					subtype => 'string',
				},
			},
		},
		DEFAULTS => {
			type => 'nested',
			child => {
				DB => {
					type => 'nested',
					optional => 1,
					child => {
						USER => { type => 'string', optional => 1 },
						PASS => { type => 'string', optional => 1 },
					},
				},
				DIR => {
					type => 'nested',
					optional => 1,
					child => {
						EXCLUDE => { type => 'array', subtype => 'string', optional => 1 },
					},
				},
				GPG => {
					type => 'nested',
					optional => 1,
					child => {
						MODE => { type => 'string', optional => 1 },
						PASS => { type => 'string', optional => 1 },
					},
				},
			},
		},
		TO => {
			type => 'hash',
			keytype => 'string',
			callback => sub {
				use Carp;
				local $Carp::CarpLevel = 1;
				my ($self, $value, $def, $path) = @_;
				for my $k (keys %$value) {
					my $v = $value->{$k};
					if ($v->{DIR} && $v->{BUCKET}) {
						croak sprintf "Config::Validate::validate(): %s: contains both a DIR and a BUCKET", mkpath([ @$path, $k ]);
					}
					if (!$v->{BUCKET} and my @wrong_keys = grep exists $v->{$_}, qw/CFG MODE PASS/) {
						croak sprintf "Config::Validate::validate(): %s: the following keys only make sense with a BUCKET: %s", mkpath([@$path, $k]), join ', ', @wrong_keys;
					}
				}
			},
			child => {
				DIR => { type => 'string', optional => 1 },
				KEEP => { type => 'integer', optional => 1 },
				BUCKET => { type => 'string', optional => 1 },
				CFG => { type => 'string', optional => 1 },
				MODE => { type => 'string', optional => 1 },
				PASS => { type => 'string', optional => 1 },
			},
		},
	};
	my $validator = Config::Validate->new(schema => $def);
	print Dumper [ $validator->validate(config => $config) ];
}

sub check_config {
	my $config = shift;

	die "$0: config must return a HASH ref!" unless ref $config eq 'HASH';

	check_keys('toplevel', $config, [qw/SETTINGS DEFAULTS TO BACKUPS/]);

	check_keys('SETTINGS', $config->{SETTINGS}, [qw/MACHINE_NAME MAILTO/]);
	check_reftype('SETTINGS.MACHINE_NAME', $config->{SETTINGS}{MACHINE_NAME}, '');
	check_reftype('SETTINGS.MAILTO', $config->{SETTINGS}{MAILTO}, 'ARRAY');

	check_keys('DEFAULTS', $config->{DEFAULTS}, [], [qw/DB DIR GPG/]);

	if ($config->{DEFAULTS}{DB}) {
		check_keys('DEFAULTS.DB', $config->{DEFAULTS}{DB}, [], [qw/USER PASS/]);
		check_reftype('DEFAULTS.DB.USER', $config->{DEFAULTS}{DB}{USER}, '') if $config->{DEFAULTS}{DB}{USER};
		check_reftype('DEFAULTS.DB.PASS', $config->{DEFAULTS}{DB}{PASS}, '') if $config->{DEFAULTS}{DB}{PASS};
	}

	if ($config->{DEFAULTS}{DIR}) {
		check_keys('DEFAULTS.DIR', $config->{DEFAULTS}{DIR}, [], [qw/EXCLUDE/]);
		check_reftype('DEFAULTS.DIR.EXCLUDE', $config->{DEFAULTS}{DIR}{EXCLUDE}, 'ARRAY') if $config->{DEFAULTS}{DIR}{EXCLUDE};
	}

	if ($config->{DEFAULTS}{GPG}) {
		check_keys('DEFAULTS.GPG', $config->{DEFAULTS}{GPG}, [], [qw/MODE PASS/]);
		check_reftype('DEFAULTS.GPG.MODE', $config->{DEFAULTS}{GPG}{MODE}, '') if $config->{DEFAULTS}{GPG}{MODE};
		check_reftype('DEFAULTS.GPG.PASS', $config->{DEFAULTS}{GPG}{PASS}, '') if $config->{DEFAULTS}{GPG}{PASS};
	}

	for my $k (keys %{ $config->{TO} }) {
		check_re("TO.$k", $k, IDENTIFIER_RE);
		my $dest_def = $config->{TO}{$k};
		if ($dest_def->{DIR}) {
			check_keys("TO.$k", $dest_def, [qw/DIR/], [qw/KEEP/]);
			check_reftype("TO.$k.DIR", $dest_def->{DIR}, '');
			check_reftype("TO.$k.KEEP", $dest_def->{KEEP}, '') if $dest_def->{KEEP};
		}
		elsif ($dest_def->{BUCKET}) {
			check_keys("TO.$k", $dest_def, [qw/BUCKET/], [qw/KEEP CFG MODE PASS/]);
			check_reftype("TO.$k.BUCKET", $dest_def->{BUCKET}, '');
			for my $key (qw/KEEP CFG MODE PASS/) {
				check_reftype("TO.$k.$key", $dest_def->{$key}, '') if $dest_def->{$key};
			}
		}
		else {
			die "$0: unknown type of TO definition $k, contains neither DIR nor BUCKET\n";
		}
	}

	for my $k (keys %{ $config->{BUCKET} }) {
		check_re("BACKUPS.$k", $k, IDENTIFIER_RE);
		my $backup_def = $config->{BUCKET}{$k};
		check_keys("BACKUPS.$k", $backup_def, [qw/FROM TO/]);

		check_reftype("BACKUPS.$k.FROM", $backup_def->{FROM}, 'HASH');
		for my $from_k (keys %{ $backup_def->{FROM} }) {
			check_re("BACKUPS.$k.FROM.$from_k", $backup_def->{FROM}{$from_k}, IDENTIFIER_RE);
		}


		check_reftype("BACKUPS.$k.TO", $backup_def->{TO}, 'ARRAY');
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

