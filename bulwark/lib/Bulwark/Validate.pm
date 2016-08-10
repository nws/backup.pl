package Bulwark::Validate;
use strict;
use warnings;

use Data::Dumper;

sub new {
	my $class = shift;
	my $self = bless { @_ }, $class;
	$self->{types} = {
		integer => { validate => \&_validate_integer },
		float => { validate => \&_validate_float },
		string => { validate => \&_validate_string },
		boolean => { validate => \&_validate_boolean },
		hash => { validate => \&_validate_hash },
		array => { validate => \&_validate_array },
		directory => { validate => \&_validate_directory },
		file => { validate => \&_validate_file },
		nested => { validate => sub { shift->throw("'nested' is not valid here") } },
	};
	return $self;
}

sub add_type {
	my $self = shift;
	my ($name, $def) = @_;
	$self->{types}{ $name } = $def;
}

sub validate {
	my $self = shift;
	my %p = @_;
	$self->_validate(config => $p{config}, schema => $self->{schema}, path => []);
	return $p{config};
}

sub _validate {
	my $self = shift;
	my %p = @_;

	for my $key (keys %{ $p{schema} }) {
		my @path = (@{ $p{path} }, $key);
		my $def = $p{schema}{ $key };


		$self->_check_definition_type($def, \@path);

		if (!exists $p{config}{ $key }) {
			$self->throw("Required item ".$self->mkpath(\@path)." was not found") unless $def->{optional};
			return;
		}

		if ($def->{type} eq 'nested') {
			$self->_validate(config => $p{config}{ $key }, schema => $def->{child}, path => \@path);
		}
		else {
			my $typeinfo = $self->{types}{ $def->{type} };
			my $validate_callback = $typeinfo->{validate};

			$self->throw("No validate callback defined for type '".$def->{type}."'") unless $validate_callback;

			$validate_callback->($self, $p{config}{ $key }, $def, \@path);
		}

		if ($def->{callback}) {
			$def->{callback}->($self, $p{config}{ $key }, $def, \@path);
		}
	}

	return;
}

sub _check_definition_type {
	my $self = shift;
	my ($def, $path) = @_;
	$self->throw("No type specified for ".$self->mkpath($path)) unless $def->{type};
	$self->throw("Invalid type '".$def->{type}."' specified for ".$self->mkpath($path)) unless $self->{types}{ $def->{type} };
}

sub throw {
	my $self = shift;
	die @_;
}

sub _debug {}

sub mkpath {
	my $self = shift;
	my ($path) = @_;

	return join '/', @$path;
}

# default type validators

sub _validate_hash {
	my ($self, $value, $def, $path) = @_;

	if (not defined $def->{keytype}) {
		$self->throw("No keytype specified for " . $self->mkpath($path));
	}

	if (not defined $self->{types}{ $def->{keytype} }) {
		$self->throw("Invalid keytype '$def->{keytype}' specified for " . $self->mkpath($path));
	}

	if (ref $value ne 'HASH') {
		$self->throw(sprintf("%s: should be a 'HASH', but instead is '%s'", $self->mkpath($path), ref $value));
	}

	foreach my $k (keys %$value) {
		my $v = $value->{$k};

		my @curpath = (@$path, $k);
		$self->_debug("Validating ", $self->mkpath(\@curpath));
		my $callback = $self->{types}{ $def->{keytype} }{validate};
		$callback->($self, $k, $def, \@curpath);
		if ($def->{child}) {
			$self->_validate(config => $v, schema => $def->{child}, path => \@curpath);
		}
	}
	return;
}

sub _validate_array {
	my ($self, $value, $def, $path) = @_;

	if (not defined $def->{subtype}) {
		$self->throw("No subtype specified for " . $self->mkpath($path));
	}

	if (not defined $self->{types}{ $def->{subtype} }) {
		$self->throw("Invalid subtype '$def->{subtype}' specified for " . $self->mkpath($path));
	}

#	if (ref $value eq 'SCALAR' and $self->{array_allows_scalar}) {
#		$$value = [ $$value ];
#		$value = $$value;
#	} elsif (ref $value eq 'REF' and ref $$value eq 'ARRAY') {
#		$value = $$value;
#	}

	if (ref $value ne 'ARRAY') {
		$self->throw(sprintf("%s: should be an 'ARRAY', but instead is a '%s'", $self->mkpath($path), ref $value));
	}

	my $index = 0;
	foreach my $item (@$value) {
		my @path = ( @$path, "[$index]" );
		$self->_debug("Validating ", $self->mkpath(\@path));
		my $callback = $self->{types}{ $def->{subtype} }{validate};
		$callback->($self, $item, $def, \@path);
		$index++;
	}
	return;
}

sub _validate_integer {
	my ($self, $value, $def, $path) = @_;
	if ($value !~ /^ -? \d+ $/xo) {
		$self->throw(sprintf("%s should be an integer, but has value of '%s' instead", $self->mkpath($path), $value));
	}
	if (defined $def->{max} and $value > $def->{max}) {
		$self->throw(sprintf("%s: %d is larger than the maximum allowed (%d)", $self->mkpath($path), $value, $def->{max}));
	}
	if (defined $def->{min} and $value < $def->{min}) {
		$self->throw(sprintf("%s: %d is smaller than the minimum allowed (%d)", $self->mkpath($path), $value, $def->{max}));
	}

	return;
}

sub _validate_float {
	my ($self, $value, $def, $path) = @_;
	if ($value !~ /^ -? \d*\.?\d+ $/xo) {
		$self->throw(sprintf("%s should be an float, but has value of '%s' instead", $self->mkpath($path), $value));
	}
	if (defined $def->{max} and $value > $def->{max}) {
		$self->throw(sprintf("%s: %f is larger than the maximum allowed (%f)", $self->mkpath($path), $value, $def->{max}));
	}
	if (defined $def->{min} and $value < $def->{min}) {
		$self->throw(sprintf("%s: %f is smaller than the minimum allowed (%f)", $self->mkpath($path), $value, $def->{max}));
	}

	return;
}

sub _validate_string {
	my ($self, $value, $def, $path) = @_;

	if (defined $def->{maxlen}) {
		if (length($value) > $def->{maxlen}) {
			$self->throw(sprintf("%s: length of string is %d, but must be less than %d", $self->mkpath($path), length($value), $def->{maxlen}));
		}
	}
	if (defined $def->{minlen}) {
		if (length($value) < $def->{minlen}) {
			$self->throw(sprintf("%s: length of string is %d, but must be greater than %d", $self->mkpath($path), length($value), $def->{minlen}));
		}
	}
	if (defined $def->{regex}) {
		if ($value !~ $def->{regex}) {
			$self->throw(sprintf("%s: regex (%s) didn't match '%s'", $self->mkpath($path), $def->{regex}, $value));
		}
	}

	return;
}

sub _validate_boolean {
	my ($self, $value, $def, $path) = @_;

	my @true  = qw(y yes t true on);
	my @false = qw(n no f false off);
	$value =~ s/\s+//xg;
	$value = 1 if any { lc($value) eq $_ } @true;
	$value = 0 if any { lc($value) eq $_ } @false;

	if ($value !~ /^ [01] $/x) {
		$self->throw(sprintf("%s: invalid value '%s', must be: %s", $self->mkpath($path), $value, join(', ', (0, 1, @true, @false))));
	}

	return;
}

sub _validate_directory {
	my ($self, $value, $def, $path) = @_;

	if (not -d $value) {
		$self->throw(sprintf("%s: '%s' is not a directory", $self->mkpath($path), $value));
	}
	return;
}

sub _validate_file {
	my ($self, $value, $def, $path) = @_;

	if (not -f $value) {
		$self->throw(sprintf("%s: '%s' is not a file", $self->mkpath($path), $value));
	}
	return;
}

1;
