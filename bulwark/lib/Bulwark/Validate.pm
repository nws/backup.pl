package Bulwark::Validate;
use strict;
use warnings;

sub new {
	my $class = shift;
	my $self = bless { @_ }, $class;
	$self->{types} = {

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
	my %_ = @_;
	$self->_validate(config => $_{config}, schema => $self->{schema});
}

sub _validate {
	my $self = shift;
	my %_ = @_;

	for my $key (keys %{ $_{schema} }) {
		
	}
}

1;
