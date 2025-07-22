package WeBWorK::ConfigObject;
use Mojo::Base -signatures;

# Base object class for all config objects
use constant SECRET_STRING => '*****';

sub new ($class, $data, $c) {
	return bless {
		%$data,                                             # Make a copy of the data.
		c    => $c,                                         # The current content generator controller object.
		name => ($data->{var} =~ s/[{]/_/gr) =~ s/[}]//gr
	}, $class;
}

# Only input is a value to display, and should produce an html string.
sub display_value ($self, $val) {
	return $self->{secret} ? SECRET_STRING : $val;
}

# This should return the value to compare to the new value.  This is *not* what is displayed.
sub comparison_value ($self, $val) {
	return $val;
}

# Get the value of the corresponding variable in the provided course environment.
sub get_value ($self, $ce) {
	my @keys = $self->{var} =~ m/([^{}]+)/g;
	return '' unless @keys;

	my $value = $ce;
	for (@keys) {
		$value = $value->{$_};
	}
	return $value;
}

# If use_current is true then return the current course environment value for this setting.
# Otherwise use the value of the html form element.
sub convert_newval_source ($self, $use_current) {
	if ($use_current) {
		return $self->comparison_value($self->get_value($self->{c}->ce));
	} else {
		return $self->{c}->param($self->{name}) // '';
	}
}

# Bit of text to put in the configuration file.  The result should be an assignment which is executable by perl.  oldval
# will be the value of the perl variable, and newval will be whatever an entry widget produces.
sub save_string ($self, $oldval, $use_current = 0) {
	my $newval = $self->convert_newval_source($use_current);
	return '' if $self->comparison_value($oldval) eq $newval || ($self->{secret} && $newval eq SECRET_STRING);

	$newval =~ s/['"`]//g;
	return "\$$self->{var} = '$newval';\n";
}

# A widget to interact with the user
sub entry_widget ($self, $default, $is_secret = 0) {
	return $self->{c}->text_field(
		$self->{name} => $is_secret ? SECRET_STRING : $default,
		id            => $self->{name},
		size          => $self->{width} || 15,
		class         => 'form-control form-control-sm'
	);
}

sub help_title           ($self) { return $self->{c}->maketext('Variable Documentation') }
sub help_name            ($self) { return '$' . $self->{var} }
sub help_link_aria_label ($self) { return $self->{c}->maketext('Variable documentation for [_1]', $self->help_name) }

# This produces the documentation string and modal containing detailed documentation.
# It is the same for all config types.
sub what_string ($self) {
	return $self->{c}->include('ContentGenerator/Instructor/Config/config_help', configObject => $self);
}

1;
