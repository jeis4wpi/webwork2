package WeBWorK::AchievementItems::DoubleProb;
use Mojo::Base 'WeBWorK::AchievementItems', -signatures;

# Item to make a problem worth double.

use WeBWorK::Utils           qw(x);
use WeBWorK::Utils::DateTime qw(after);

sub new ($class) {
	return bless {
		id          => 'DoubleProb',
		name        => x('Cupcake of Enlargement'),
		description => x('Causes a single homework problem to be worth twice as much.')
	}, $class;
}

sub can_use ($self, $set, $records) {
	return $set->assignment_type eq 'default' && after($set->open_date);
}

sub print_form ($self, $set, $records, $c) {
	return WeBWorK::AchievementItems::form_popup_menu_row(
		$c,
		id         => 'dbp_problem_id',
		label_text => $c->maketext('Problem number to double weight'),
		first_item => $c->maketext('Choose problem to double its weight.'),
		values     => [
			map { [ $c->maketext('Problem [_1] ([_2] to [_3])', $_->problem_id, $_->value, 2 * $_->value) =>
					$_->problem_id ] } @$records
		],
	);
}

sub use_item ($self, $set, $records, $c) {
	my $problemID = $c->param('dbp_problem_id');
	unless ($problemID) {
		$c->addbadmessage($c->maketext('Select problem to double its weight with the [_1].', $self->name));
		return '';
	}

	my $problem;
	for (@$records) {
		if ($_->problem_id == $problemID) {
			$problem = $_;
			last;
		}
	}
	return '' unless $problem;

	# Double the value of the problem.
	my $db          = $c->db;
	my $userProblem = $db->getUserProblem($problem->user_id, $problem->set_id, $problem->problem_id);
	my $orig_value  = $problem->value;
	$problem->value($orig_value * 2);
	$userProblem->value($problem->value);
	$db->putUserProblem($userProblem);

	return $c->maketext('Problem [_1] weight increased from [_2] to [_3].', $problemID, $orig_value, $problem->value);
}

1;
