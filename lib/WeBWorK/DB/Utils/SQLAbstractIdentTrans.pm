package WeBWorK::DB::Utils::SQLAbstractIdentTrans;
use parent qw(SQL::Abstract);

=head1 NAME

WeBWorK::DB::Utils::SQLAbstractIdentTrans - subclass of SQL::Abstract::Classic that
allows custom hooks to transform table names.

=cut

use strict;
use warnings;

sub _table {
	my ($self, $from) = @_;
	if (ref($from) eq 'ARRAY') {
		return $self->SUPER::_table([ map { $self->_transform_table($_) } @$from ]);
	} elsif (!ref($from)) {
		return $self->SUPER::_table($self->_transform_table($from));
	}
	return $self->SUPER::_table($from);
}

sub _quote {
	my ($self, $label) = @_;

	return $label if $label eq '*';

	return join($self->{name_sep} || '', map { $self->_quote($_) } @$label) if ref($label) eq 'ARRAY';

	return $self->SUPER::_quote($label) unless defined $self->{name_sep};

	if (ref($self->{transform_all}) eq 'CODE') {
		return $self->{transform_all}->($label);
	} elsif ($label =~ /(.+)\.(.+)/) {
		return $self->SUPER::_quote($self->_transform_table($1)) . $self->{name_sep} . $self->SUPER::_quote($2);
	} else {
		return $self->SUPER::_quote($label);
	}
}

sub _transform_table {
	my ($self, $table) = @_;
	return ref($self->{transform_table}) eq 'CODE' ? $self->{transform_table}->($table) : $table;
}

sub insert {
	my ($self, $table, $data, $options) = @_;
	return $self->SUPER::insert($self->_transform_table($table), $data, $options);
}

sub update {
	my ($self, $table, $set, $where, $options) = @_;
	return $self->SUPER::update($self->_transform_table($table), $set, $where, $options);
}

sub delete {
	my ($self, $table, $where, $options) = @_;
	return $self->SUPER::delete($self->_transform_table($table), $where, $options);
}

1;
