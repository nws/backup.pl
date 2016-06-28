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

	check_reftype('settings.mailto', $config->{SETTINGS}{MAILTO}, 'ARRAY');

	check_keys('defaults', $config->{DEFAULTS}, [], [qw/DB DIR GPG/]);

	# XXX

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
	die "$0: bad value in config in $section, expected $want_ref_type, got @{[$got_ref_type || $value]}\n" if $got_ref_type ne $want_ref_type;
}

__END__
my $c = do "lucy.cfg.pl";

print Dumper $c;
print Dumper $@;
print Dumper $!;

