#!/usr/bin/env perl
use strict;
use warnings;

our $VERSION = '0.1';

use Data::Dumper;
use Getopt::Long;

GetOptions
	'config=s' => \my $config_file,
	'dump-config' => \my $dump_config,
	'dry-run' => \my $dry_run,
	'verbose' => \my $verbose
	or die usage();

die usage() unless defined $config_file;

my $config = read_config($config_file);

if ($dump_config) {
	use Data::Dumper;
	print Data::Dumper
		->new([$config])
		->Sortkeys(1)
		->Quotekeys(0)
		->Indent(1)
		->Terse(1)
		->Useqq(1)
		->Dump;
	exit;
}

sub usage {
	<<EOS;
$0 --config FILE [--dry-run] [--verbose] [--dump-config]
v$VERSION
EOS
}

exit 0;

sub read_config {
	my $config_file = shift;
	my $config = do $config_file;

	if (defined $config) {
		return check_config($config);
	}

	die "$0: can not read file $config_file: $!\n" if $!;
	die "$0: can not parse file $config_file:\n $@\n" if $@;
	die "$0: empty config file $config_file?\n";
}

sub check_config {
	my $config = shift;
	use Bulwark::Validate;

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
		BACKUPS => {
			type => 'hash',
			keytype => 'string',
			child => {
				FROM => {
					type => 'hash',
					keytype => 'string',
					child => {
						DB => { type => 'array', subtype => 'string', optional => 1 },
						DIR => { type => 'string', optional => 1 },
						EXCLUDE => { type => 'array', subtype => 'string', optional => 1 },
					},
				},
				TO => {
					type => 'array',
					subtype => 'string',
				},
			},
		},
	};
	# XXX lots more validation to be done:
	# two types of things that go into a FROM need to be distinguished and validated
	# various strings have to be checked (value of TO, etc)
	# stuff that goes into filenames needs more rigorous checking
	my $validator = Bulwark::Validate->new(schema => $def);
	return $validator->validate(config => $config);
}

